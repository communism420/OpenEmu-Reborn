// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

import AppKit
import OpenEmuBase

/// A marker prevents a disconnected/replaced disk from becoming a new, empty
/// library at the same path. The bookmark, not a copy of the library, is kept
/// in macOS preferences so the app can find the folder on its next launch.
struct OEDataFolderIdentity: Codable, Equatable {
    static let fileName = ".openemu-data-folder.plist"
    let version: Int
    let identifier: UUID

    static func read(at root: URL) throws -> Self {
        let marker = root.appendingPathComponent(fileName)
        let properties = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try Data(contentsOf: marker)
        let identity = try PropertyListDecoder().decode(Self.self, from: data)
        guard identity.version == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return identity
    }

    /// Never changes an existing marker or adopts another library during recovery.
    static func prepare(at root: URL, expectedID: UUID? = nil) throws -> Self {
        try prepareForUse(at: root, expectedID: expectedID).identity
    }

    /// Only the call that creates the marker may import legacy preferences.
    /// A missing Settings.plist in an already marked folder means a fresh start,
    /// not permission to restore settings the user has removed.
    static func prepareForUse(at root: URL, expectedID: UUID? = nil) throws -> (identity: Self, createdMarker: Bool) {
        let fm = FileManager.default
        let properties = try root.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard root.isFileURL, root.standardizedFileURL.path != "/",
              properties.isDirectory == true, properties.isPackage != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let marker = root.appendingPathComponent(fileName)
        if fm.fileExists(atPath: marker.path) {
            let identity = try read(at: root)
            guard expectedID == nil || identity.identifier == expectedID else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (identity, false)
        }
        guard expectedID == nil else { throw CocoaError(.fileNoSuchFile) }

        let entries = try fm.contentsOfDirectory(atPath: root.path).filter { $0 != ".DS_Store" }
        // Existing OpenEmu folders may be adopted, but an unrelated Documents
        // or Downloads folder must not become the application's data root.
        let legacyLibrary = root.appendingPathComponent("Game Library/Library.storedata")
        guard entries.isEmpty || fm.fileExists(atPath: legacyLibrary.path) else {
            throw NSError(domain: "org.openemu.DataFolder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Choose an empty folder or an existing OpenEmu data folder.", comment: "Data folder validation")
            ])
        }
        let identity = Self(version: 1, identifier: UUID())
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        // Exclusive creation protects another process/library's marker.
        try encoder.encode(identity).write(to: marker, options: .withoutOverwriting)
        return (identity, true)
    }
}

@MainActor
enum OEDataFolderSetup {
    // Use the same injected-XCTest boundary for storage and app startup.
    // A normal launch (including Release smoke tests) keeps the full UI.
    nonisolated static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let bootstrapDomain = "org.openemu.OpenEmu"
    static let bookmarkKey = "OEDataFolderBookmark"
    static let identifierKey = "OEDataFolderIdentifier"
    static let pathKey = "OEDataFolderPath"
    private static let lastRootPathKey = "OEDataFolderLastPath"
    private static let storedPathKeys = ["databasePath", "defaultDatabasePath", "saveStateFolder", "screenshotFolder", "OEBackupFolderPath"]
    private static var failureObserver: NSObjectProtocol?
    private static var showingWriteFailure = false

    static func configureOrQuit() {
        // Debug has a different bundle identifier, but both app variants and
        // the core install scripts must find the same chosen data folder.
        // Only these locator values use the shared macOS preferences domain.
        // Foundation rejects a suite whose name is the active app's own
        // bundle identifier. Release already uses this domain as standard;
        // only Debug needs to open the shared Release domain as another suite.
        guard let defaults = locatorDefaults(for: Bundle.main.bundleIdentifier) else {
            FileHandle.standardError.write(Data("OpenEmu could not open its data-folder locator.\n".utf8))
            exit(EXIT_FAILURE)
        }

        // App-hosted XCTest must never block on a picker or reuse the real
        // user's library, including Release tests. This directory belongs only
        // to the injected XCTest process.
        if isRunningUnitTests {
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenEmuTests-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                _ = try OEDataFolderIdentity.prepare(at: root)
                try activate(root, migrateLegacySettings: false)
                return
            } catch {
                FileHandle.standardError.write(Data("OpenEmu test data folder: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }

        // Explicit command-line selection is useful for isolated build smoke
        // tests. It does not replace the folder remembered for ordinary launches.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--data-folder") {
            do {
                guard index + 1 < arguments.count, (arguments[index + 1] as NSString).isAbsolutePath else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
                let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                _ = try OEDataFolderIdentity.prepare(at: root)
                try activate(root, migrateLegacySettings: false)
                return
            } catch {
                FileHandle.standardError.write(Data("OpenEmu data folder: \(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }

        let expectedID = defaults.string(forKey: identifierKey).flatMap(UUID.init(uuidString:))
        if let bookmark = defaults.data(forKey: bookmarkKey) {
            while true {
                do {
                    guard let expectedID else { throw CocoaError(.fileReadCorruptFile) }
                    var stale = false
                    let root = try URL(resolvingBookmarkData: bookmark,
                                       options: [.withoutUI, .withoutMounting],
                                       relativeTo: nil, bookmarkDataIsStale: &stale)
                    _ = try OEDataFolderIdentity.prepare(at: root, expectedID: expectedID)
                    try activate(root)
                    if stale || defaults.string(forKey: pathKey) != root.path {
                        try remember(root, identifier: expectedID, in: defaults)
                    }
                    return
                } catch {
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("OpenEmu cannot open its data folder", comment: "Missing data folder")
                    alert.informativeText = String(format: NSLocalizedString("Connect the disk and try again, or locate the same folder. Your library will not be replaced.\n\n%@\n\n%@", comment: "Missing data folder explanation"), defaults.string(forKey: pathKey) ?? "", error.localizedDescription)
                    alert.addButton(withTitle: NSLocalizedString("Try Again", comment: "Retry data folder"))
                    alert.addButton(withTitle: NSLocalizedString("Locate Folder…", comment: "Locate data folder"))
                    alert.addButton(withTitle: NSLocalizedString("Quit OpenEmu", comment: "Quit during setup"))
                    switch alert.runModal() {
                    case .alertFirstButtonReturn: continue
                    case .alertSecondButtonReturn:
                        guard let expectedID else { exit(EXIT_FAILURE) }
                        chooseFolder(expectedID: expectedID, defaults: defaults)
                        return
                    default: exit(EXIT_SUCCESS)
                    }
                }
            }
        }

        // An incomplete bootstrap must not silently select a fresh library.
        if defaults.object(forKey: identifierKey) != nil || defaults.object(forKey: pathKey) != nil {
            guard let expectedID else { exit(EXIT_FAILURE) }
            chooseFolder(expectedID: expectedID, defaults: defaults)
        } else {
            chooseFolder(expectedID: nil, defaults: defaults)
        }
    }

    static func locatorDefaults(for bundleIdentifier: String?) -> UserDefaults? {
        if bundleIdentifier == bootstrapDomain { return .standard }
        return UserDefaults(suiteName: bootstrapDomain)
    }

    static func makeResetSettingsAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Reset all settings and quit OpenEmu?", comment: "Settings reset confirmation")
        alert.informativeText = NSLocalizedString("All OpenEmu preferences, controller mappings and saved sign-ins in the current data folder will be reset. On the next launch, you will choose a data folder and complete setup again.\n\nGames, BIOS, saves and cores will not be deleted. Choose the same data folder again to keep using its library. macOS permissions will not change.\n\nThis cannot be undone after confirmation.", comment: "Settings reset explanation")
        let cancel = alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel settings reset"))
        cancel.keyEquivalent = "\r"
        let reset = alert.addButton(withTitle: NSLocalizedString("Reset and Quit", comment: "Confirm settings reset"))
        reset.keyEquivalent = ""
        reset.hasDestructiveAction = true
        return alert
    }

    static func resetApplicationDefaults() {
        // An isolated test/profile must never erase the real user's locator
        // or framework settings. Its next --data-folder launch still runs setup.
        guard !ProcessInfo.processInfo.arguments.contains("--data-folder"),
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let domain = Bundle.main.bundleIdentifier,
              [bootstrapDomain, bootstrapDomain + ".debug"].contains(domain) else { return }
        clearApplicationDefaults(in: .standard, domains: [bootstrapDomain, domain])
    }

    static func clearApplicationDefaults(in defaults: UserDefaults, domains: [String]) {
        for domain in Set(domains) { defaults.removePersistentDomain(forName: domain) }
        defaults.synchronize()
    }

    private static func chooseFolder(expectedID: UUID?, defaults: UserDefaults) {
        while true {
            let panel = makeFolderPanel(isRecovery: expectedID != nil)
            if let path = defaults.string(forKey: pathKey) {
                panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
            }
            NSApp.activate(ignoringOtherApps: true)
            guard runFolderPanel(panel) == .OK, let root = panel.url else { exit(EXIT_SUCCESS) }
            do {
                let preparation = try OEDataFolderIdentity.prepareForUse(at: root, expectedID: expectedID)
                // Make the bookmark before fixing the root for this process.
                let bookmark = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                try activate(root, migrateLegacySettings: preparation.createdMarker)
                defaults.set(bookmark, forKey: bookmarkKey)
                defaults.set(preparation.identity.identifier.uuidString, forKey: identifierKey)
                defaults.set(root.path, forKey: pathKey)
                return
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = NSLocalizedString("This folder cannot be used", comment: "Data folder validation failure")
                alert.runModal()
                // Once initialized, path caches must never be redirected.
                if OEStoragePaths.isConfigured || OEPreferences.isConfigured { exit(EXIT_FAILURE) }
            }
        }
    }

    static func makeFolderPanel(isRecovery: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Choose OpenEmu Data Folder", comment: "First launch folder picker")
        panel.message = panel.title
        panel.prompt = NSLocalizedString("Use This Folder", comment: "Confirm data folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = !isRecovery
        panel.allowsMultipleSelection = false

        // A long native message can make the file panel wider than the screen.
        // Keep the complete explanation in a width-bounded, wrapping accessory.
        let explanation = isRecovery
            ? NSLocalizedString("Locate the OpenEmu data folder you previously selected. A different or empty folder will not replace your library.", comment: "Recovery folder picker explanation")
            : NSLocalizedString("Choose or create a dedicated folder for your game library, imported games, BIOS, saves, cores, settings, shaders and caches. Existing data is not moved automatically. To keep using an old library, select its OpenEmu data folder.", comment: "First launch folder picker explanation")
        let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        // Size the accessory BEFORE attaching it. A bare text field exposes
        // its intrinsic width to the native panel's initial minimum-size pass,
        // even when preferredMaxLayoutWidth is set later.
        panel.accessoryView = FolderExplanationView(
            text: explanation, width: explanationWidth(for: folderPanelFrame(in: visibleFrame)))
        panel.isAccessoryViewDisclosed = true
        return panel
    }

    static func folderPanelFrame(in visibleFrame: NSRect) -> NSRect {
        let available = visibleFrame.insetBy(dx: 12, dy: 12)
        let size = NSSize(width: min(720, available.width), height: min(520, available.height))
        return NSRect(x: available.midX - size.width / 2,
                      y: available.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func fitFolderPanel(_ panel: NSOpenPanel, in visibleFrame: NSRect, initially: Bool = true) {
        let available = visibleFrame.insetBy(dx: 12, dy: 12)
        var frame = initially ? folderPanelFrame(in: visibleFrame) : panel.frame
        frame.size.width = min(frame.width, available.width)
        frame.size.height = min(frame.height, available.height)
        (panel.accessoryView as? FolderExplanationView)?.fit(width: explanationWidth(for: frame))
        panel.contentView?.layoutSubtreeIfNeeded()
        if panel.frame.size != frame.size { panel.setFrame(frame, display: false) }
        // Respect native control sizes and the user's resizing/moving. After
        // the initial placement, only correct an out-of-bounds window.
        frame = panel.frame
        let origin = NSPoint(
            x: initially ? available.midX - frame.width / 2 : min(max(frame.minX, available.minX), available.maxX - frame.width),
            y: initially ? available.midY - frame.height / 2 : min(max(frame.minY, available.minY), available.maxY - frame.height))
        if frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    static func runFolderPanel(_ panel: NSOpenPanel) -> NSApplication.ModalResponse {
        let sizing = FolderPanelSizing(panel: panel)
        // Native layout/restored geometry may run after runModal starts. Refit
        // on the NEXT modal-loop turn, including late same-screen resizes.
        let center = NotificationCenter.default
        let observers = [NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification,
                         NSWindow.didResizeNotification,
                         NSApplication.didChangeScreenParametersNotification].map { name in
            center.addObserver(forName: name, object: name == NSApplication.didChangeScreenParametersNotification ? nil : panel,
                               queue: .main) { _ in
                MainActor.assumeIsolated { sizing.scheduleFit() }
            }
        }
        defer {
            sizing.isActive = false
            observers.forEach(center.removeObserver)
        }
        if let screen = panel.screen ?? NSScreen.main {
            fitFolderPanel(panel, in: screen.visibleFrame)
        }
        sizing.scheduleFit()
        return panel.runModal()
    }

    private static func explanationWidth(for frame: NSRect) -> CGFloat {
        // Leave room for the file browser's sidebar and native margins.
        max(1, min(480, frame.width - 240))
    }

    private final class FolderExplanationView: NSView {
        private let label: NSTextField

        init(text: String, width: CGFloat) {
            label = NSTextField(wrappingLabelWithString: text)
            super.init(frame: .zero)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.autoresizingMask = [.width, .height]
            addSubview(label)
            fit(width: width)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func fit(width: CGFloat) {
            label.preferredMaxLayoutWidth = width
            let height = label.cell?.cellSize(forBounds: NSRect(
                x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0
            let size = NSSize(width: width, height: ceil(height))
            if frame.size != size { setFrameSize(size) }
            label.frame = NSRect(origin: .zero, size: size)
        }
    }

    @MainActor
    private final class FolderPanelSizing {
        let panel: NSOpenPanel
        var isActive = true
        private var isPending = false

        init(panel: NSOpenPanel) { self.panel = panel }

        func scheduleFit() {
            guard isActive, !isPending else { return }
            isPending = true
            // DispatchQueue.main alone does not reliably run during startup's
            // nested modal loop. Coalescing also avoids synchronous relayout.
            RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    defer { self.isPending = false }
                    guard self.isActive, let screen = self.panel.screen ?? NSScreen.main else { return }
                    fitFolderPanel(self.panel, in: screen.visibleFrame, initially: false)
                }
            }
        }
    }

    private static func activate(_ root: URL, migrateLegacySettings: Bool = false) throws {
        // Create only inside an existing, identified root. Missing disks are
        // rejected by configure(), never recreated by this startup path.
        // Acquire the writer lease before even the storage write-check: a new
        // launch must not recreate files while the removal worker is finishing.
        let settingsURL = root.appendingPathComponent("Settings.plist")
        try OEPreferences.configure(url: settingsURL, readOnly: false)
        let hadSettings = FileManager.default.fileExists(atPath: settingsURL.path)
        try OEStoragePaths.configure(dataRootURL: root)
        for url in [OEStoragePaths.cachesURL, OEStoragePaths.temporaryDirectoryURL, OEStoragePaths.logsURL] {
            try OEStoragePaths.createDirectory(at: url)
        }
        let settings = OEPreferences.shared
        if !hadSettings, migrateLegacySettings,
           FileManager.default.fileExists(atPath: root.appendingPathComponent("Game Library/Library.storedata").path) {
            // Adopt app settings once when the user explicitly selects their
            // existing data folder. Debug must also find old Release settings;
            // any settings from the active variant take precedence.
            let defaults = UserDefaults.standard
            let releaseSettings = defaults.persistentDomain(forName: bootstrapDomain) ?? [:]
            let activeSettings = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
            let legacy = combinedLegacySettings(release: releaseSettings, active: activeSettings)
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            let oldRoot = support.appendingPathComponent("OpenEmu", isDirectory: true)
            let migrated = migratedLegacySettings(legacy, from: oldRoot.path, to: OEStoragePaths.dataRootURL.path)
            // One failed write must not leave a partial Settings.plist that
            // would cause the next launch to skip the remaining legacy settings.
            try settings.setValues(migrated)
        }
        let previousRoot = settings.string(forKey: lastRootPathKey)
        if let previousRoot, previousRoot != OEStoragePaths.dataRootURL.path {
            var rebasedValues: [String: Any] = [:]
            for key in storedPathKeys {
                guard let value = settings.string(forKey: key),
                      let rebased = rebasedPath(value, from: previousRoot, to: OEStoragePaths.dataRootURL.path) else { continue }
                rebasedValues[key] = rebased
            }
            try settings.setValues(rebasedValues)
        }
        settings.set(OEStoragePaths.dataRootURL.path, forKey: lastRootPathKey)
        try checkSettingsWrite()
        observeWriteFailures()
    }

    static func combinedLegacySettings(release: [String: Any], active: [String: Any]) -> [String: Any] {
        release.merging(active) { _, activeValue in activeValue }
    }

    /// Old releases have no remembered data root. Only paths inside their
    /// standard Application Support/OpenEmu directory can safely be rebased;
    /// explicitly chosen external locations must retain their original paths.
    static func migratedLegacySettings(_ legacy: [String: Any], from oldRoot: String, to newRoot: String) -> [String: Any] {
        var migrated = legacy.filter { key, _ in
            !key.hasPrefix("NS") && !key.hasPrefix("SU") && !key.hasPrefix("OEDataFolder")
        }
        for key in storedPathKeys {
            guard let value = migrated[key] as? String,
                  let rebased = rebasedPath(value, from: oldRoot, to: newRoot) else { continue }
            migrated[key] = rebased
        }
        return migrated
    }

    /// Preserve explicitly external locations; move only paths inside our root.
    static func rebasedPath(_ value: String, from oldRoot: String, to newRoot: String) -> String? {
        let isURL = value.hasPrefix("file:")
        let path = isURL ? URL(string: value)?.path : (value as NSString).expandingTildeInPath
        guard let path else { return nil }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let old = URL(fileURLWithPath: oldRoot).standardizedFileURL.path
        guard normalized == old || normalized.hasPrefix(old + "/") else { return nil }
        let newPath = newRoot + normalized.dropFirst(old.count)
        return isURL ? URL(fileURLWithPath: newPath).absoluteString : newPath
    }

    private static func checkSettingsWrite() throws {
        guard OEPreferences.shared.synchronize() else {
            throw NSError(domain: "org.openemu.DataFolder", code: 2, userInfo: [NSLocalizedDescriptionKey:
                NSLocalizedString("OpenEmu could not save its settings. Check that the data disk is connected and writable.", comment: "Settings write failure")])
        }
    }

    private static func observeWriteFailures() {
        guard failureObserver == nil else { return }
        failureObserver = NotificationCenter.default.addObserver(forName: Notification.Name("OEPreferencesPersistenceDidFailNotification"), object: nil, queue: nil) { notification in
            let error = notification.userInfo?[NSUnderlyingErrorKey] as? NSError
            // The writer may hold a lock; never synchronously enter the UI from it.
            DispatchQueue.main.async {
                guard !showingWriteFailure else { return }
                showingWriteFailure = true
                defer { showingWriteFailure = false }
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("OpenEmu could not save its settings", comment: "Settings write failure title")
                alert.informativeText = error?.localizedDescription ?? NSLocalizedString("Check that the data disk is connected and writable. The previous settings were kept.", comment: "Settings write failure explanation")
                alert.runModal()
            }
        }
    }

    private static func remember(_ root: URL, identifier: UUID, in defaults: UserDefaults) throws {
        let bookmark = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: bookmarkKey)
        defaults.set(identifier.uuidString, forKey: identifierKey)
        defaults.set(root.path, forKey: pathKey)
    }
}

/// Reset only known settings files. Do not remove the folder, its marker/lock,
/// user assets, game library, BIOS or saves. Empty files prevent legacy import.
enum OEDataFolderSettingsReset {
    static func perform(at root: URL, emptyCredentials: Data, validateRoot: () throws -> Void,
                        resetPreferences: () throws -> Void) throws {
        let fm = FileManager.default
        func attributes(at url: URL) throws -> [FileAttributeKey: Any]? {
            do { return try fm.attributesOfItem(atPath: url.path) }
            catch CocoaError.fileReadNoSuchFile { return nil }
        }
        try validateRoot()
        guard try attributes(at: root)?[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        _ = try OEDataFolderIdentity.read(at: root)
        let emptyBindings = try PropertyListSerialization.data(fromPropertyList: [String: String](), format: .binary, options: 0)
        var replacements = [(root.appendingPathComponent(".oe_credentials"), emptyCredentials)]
        let bindings = root.appendingPathComponent("Bindings", isDirectory: true)
        if let info = try attributes(at: bindings) {
            guard info[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            for url in try fm.contentsOfDirectory(at: bindings, includingPropertiesForKeys: nil)
                where url.pathExtension.lowercased() == "oebindings" {
                replacements.append((url, emptyBindings))
            }
        }
        // Capture all originals before changing any file. In particular, reject
        // symbolic links instead of resetting something outside the data folder.
        let originals = try replacements.map { url, _ -> (URL, Data?, [FileAttributeKey: Any]?) in
            let info = try attributes(at: url)
            guard info == nil || info?[.type] as? FileAttributeType == .typeRegular else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            return (url, try info == nil ? nil : Data(contentsOf: url), info)
        }
        var attempted = 0
        func validateTarget(_ url: URL) throws {
            try validateRoot()
            guard try attributes(at: url.deletingLastPathComponent())?[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let info = try attributes(at: url)
            guard info == nil || info?[.type] as? FileAttributeType == .typeRegular else {
                throw CocoaError(.fileReadInvalidFileName)
            }
        }
        do {
            for (url, data) in replacements {
                try validateTarget(url)
                attempted += 1
                try data.write(to: url, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            // The preferences store commits last and disables all late writers.
            // Nothing fallible is done after that irreversible commit.
            try validateRoot()
            try resetPreferences()
        } catch {
            var rollbackFailed = false
            for (url, data, info) in originals.prefix(attempted).reversed() {
                do {
                    try validateTarget(url)
                    if let data {
                        try data.write(to: url, options: .atomic)
                        if let mode = info?[.posixPermissions] {
                            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
                        }
                    } else if fm.fileExists(atPath: url.path) {
                        try fm.removeItem(at: url)
                    }
                } catch { rollbackFailed = true }
            }
            if rollbackFailed {
                throw NSError(domain: "org.openemu.SettingsReset", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: NSLocalizedString("The reset could not finish, and some settings could not be restored. Reconnect the data disk and check its permissions before trying again.", comment: "Settings reset rollback failure"),
                    NSUnderlyingErrorKey: error
                ])
            }
            throw error
        }
    }
}

/// A small Cocoa-bindings adapter, not an NSUserDefaults subclass. Storyboard
/// objects and programmatic bindings use the same file-backed values object.
/// It owns no mutable or UI state; all values live in the lock-protected store.
/// Accessing the adapter need not enter the main actor, including during deinit.
@objc(OEPreferencesController)
final class OEPreferencesController: NSObject, @unchecked Sendable {
    @objc static let shared = OEPreferencesController()
    @objc dynamic var values: OEPreferences { .shared }
}
