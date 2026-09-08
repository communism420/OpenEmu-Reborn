// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
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

private func check(_ condition: Bool, _ message: String) {
    guard condition else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

private func expectFailure(_ message: String, _ operation: () throws -> Void) {
    do {
        try operation()
        check(false, message)
    } catch {}
}

private final class BindingObserver: NSObject {
    var changes = 0
    var previous: Any?
    var next: Any?

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        changes += 1
        previous = change?[.oldKey]
        next = change?[.newKey]
    }
}

// Record the requested domains without accessing any real app preferences.
private final class ResetDefaults: UserDefaults, @unchecked Sendable {
    var removedDomains = Set<String>()
    var didSynchronize = false
    override func removePersistentDomain(forName domainName: String) { removedDomains.insert(domainName) }
    override func synchronize() -> Bool { didSynchronize = true; return true }
}

@main
private struct DataFolderSetupSmokeTests {
    @MainActor
    static func main() throws {
        check(CommandLine.arguments.count == 2, "explicit isolated temporary directory required")
        let workspace = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default
        for screen in [NSRect(x: 0, y: 40, width: 1280, height: 720),
                       NSRect(x: 0, y: 24, width: 1024, height: 640),
                       NSRect(x: -1280, y: -200, width: 1280, height: 720)] {
            let frame = OEDataFolderSetup.folderPanelFrame(in: screen)
            check(screen.insetBy(dx: 12, dy: 12).contains(frame), "folder panel fits the usable screen area")
            check(frame.width <= 720 && frame.height <= 520, "folder panel has a compact initial size")
            check(frame.midX == screen.midX && frame.midY == screen.midY, "folder panel centers on the correct display")
        }
        check(OEDataFolderSetup.locatorDefaults(for: OEDataFolderSetup.bootstrapDomain) === UserDefaults.standard,
              "Release uses its standard domain instead of an invalid same-name suite")
        check(OEDataFolderSetup.locatorDefaults(for: "org.openemu.OpenEmu.debug") != nil,
              "Debug can open the shared Release locator domain")
        let resetDefaults = ResetDefaults()
        OEDataFolderSetup.clearApplicationDefaults(in: resetDefaults,
            domains: [OEDataFolderSetup.bootstrapDomain, OEDataFolderSetup.bootstrapDomain + ".debug"])
        check(resetDefaults.removedDomains == ["org.openemu.OpenEmu", "org.openemu.OpenEmu.debug"]
              && resetDefaults.didSynchronize, "reset clears only the supplied app domains, including their locators")
        func directory(_ name: String) throws -> URL {
            let url = workspace.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }

        let empty = try directory("Данные OpenEmu с пробелами")
        try Data().write(to: empty.appendingPathComponent(".DS_Store"))
        let firstPreparation = try OEDataFolderIdentity.prepareForUse(at: empty)
        let identity = firstPreparation.identity
        check(firstPreparation.createdMarker, "first preparation reports exclusive creation of the marker")
        check(identity.version == 1, "empty directory receives current identity version")
        check(try OEDataFolderIdentity.read(at: empty) == identity, "identity marker roundtrip")
        let marker = empty.appendingPathComponent(OEDataFolderIdentity.fileName)
        let markerBefore = try Data(contentsOf: marker)
        check(try OEDataFolderIdentity.prepare(at: empty, expectedID: identity.identifier) == identity,
              "known directory retains identity")
        let knownPreparation = try OEDataFolderIdentity.prepareForUse(at: empty, expectedID: identity.identifier)
        check(!knownPreparation.createdMarker && knownPreparation.identity == identity,
              "remembered or recovery folder cannot enable a fresh legacy settings import")
        expectFailure("foreign identity must not be adopted") {
            _ = try OEDataFolderIdentity.prepare(at: empty, expectedID: UUID())
        }
        check(try Data(contentsOf: marker) == markerBefore, "failed recovery does not overwrite marker")

        let recoveryEmpty = try directory("empty-recovery")
        expectFailure("recovery cannot create a new identity") {
            _ = try OEDataFolderIdentity.prepare(at: recoveryEmpty, expectedID: identity.identifier)
        }
        check(!fm.fileExists(atPath: recoveryEmpty.appendingPathComponent(OEDataFolderIdentity.fileName).path),
              "failed recovery leaves directory untouched")

        let foreign = try directory("foreign-folder")
        try Data("unrelated user data".utf8).write(to: foreign.appendingPathComponent("Document.txt"))
        expectFailure("unrelated nonempty directory rejected") { _ = try OEDataFolderIdentity.prepare(at: foreign) }
        check(try fm.contentsOfDirectory(atPath: foreign.path) == ["Document.txt"], "unrelated files remain unchanged")

        let legacy = try directory("legacy")
        let legacyLibrary = legacy.appendingPathComponent("Game Library", isDirectory: true)
        try fm.createDirectory(at: legacyLibrary, withIntermediateDirectories: false)
        try Data("legacy library sentinel".utf8).write(to: legacyLibrary.appendingPathComponent("Library.storedata"))
        let legacyPreparation = try OEDataFolderIdentity.prepareForUse(at: legacy)
        let legacyIdentity = legacyPreparation.identity
        check(legacyPreparation.createdMarker, "first explicit adoption of an unmarked legacy library permits migration")
        check(legacyIdentity.identifier != identity.identifier, "existing library gets its own identity")
        let legacyMarker = try Data(contentsOf: legacy.appendingPathComponent(OEDataFolderIdentity.fileName))
        let legacySettings = legacy.appendingPathComponent("Settings.plist")
        try Data("settings removed by fixture reset".utf8).write(to: legacySettings)
        try fm.removeItem(at: legacySettings)
        let resetPreparation = try OEDataFolderIdentity.prepareForUse(at: legacy)
        check(!resetPreparation.createdMarker && resetPreparation.identity == legacyIdentity,
              "kept legacy library without Settings.plist never authorizes another legacy import")
        check(try Data(contentsOf: legacy.appendingPathComponent(OEDataFolderIdentity.fileName)) == legacyMarker,
              "reset-folder preparation preserves the existing identity marker byte-for-byte")

        let linked = try directory("linked-marker")
        try fm.createSymbolicLink(at: linked.appendingPathComponent(OEDataFolderIdentity.fileName), withDestinationURL: marker)
        expectFailure("symbolic-link marker rejected on read") { _ = try OEDataFolderIdentity.read(at: linked) }
        expectFailure("symbolic-link marker rejected on prepare") { _ = try OEDataFolderIdentity.prepare(at: linked) }
        check(try Data(contentsOf: marker) == markerBefore, "symbolic-link target not modified")

        let missingUUID = try directory("missing-uuid")
        let missingUUIDData = try PropertyListSerialization.data(fromPropertyList: ["version": 1], format: .xml, options: 0)
        try missingUUIDData.write(to: missingUUID.appendingPathComponent(OEDataFolderIdentity.fileName))
        expectFailure("marker without UUID rejected") { _ = try OEDataFolderIdentity.read(at: missingUUID) }
        let future = try directory("future-marker")
        try PropertyListEncoder().encode(OEDataFolderIdentity(version: 2, identifier: UUID()))
            .write(to: future.appendingPathComponent(OEDataFolderIdentity.fileName))
        expectFailure("unknown marker version rejected") { _ = try OEDataFolderIdentity.prepare(at: future) }

        let missing = workspace.appendingPathComponent("missing-root", isDirectory: true)
        expectFailure("missing root is not created") { _ = try OEDataFolderIdentity.prepare(at: missing) }
        check(!fm.fileExists(atPath: missing.path), "missing root remains absent")
        expectFailure("filesystem root rejected") { _ = try OEDataFolderIdentity.prepare(at: URL(fileURLWithPath: "/")) }
        expectFailure("regular file cannot become root") { _ = try OEDataFolderIdentity.prepare(at: foreign.appendingPathComponent("Document.txt")) }

        let oldRoot = "/Volumes/Old Disk/OpenEmu Данные"
        let newRoot = "/Volumes/New Disk/OpenEmu Данные"
        check(OEDataFolderSetup.rebasedPath(oldRoot + "/Game Library", from: oldRoot, to: newRoot) == newRoot + "/Game Library",
              "internal absolute path is rebased")
        check(OEDataFolderSetup.rebasedPath(oldRoot, from: oldRoot, to: newRoot) == newRoot, "root path itself is rebased")
        let oldURL = URL(fileURLWithPath: oldRoot + "/Save States")
        check(OEDataFolderSetup.rebasedPath(oldURL.absoluteString, from: oldRoot, to: newRoot)
              == URL(fileURLWithPath: newRoot + "/Save States").absoluteString, "internal file URL is rebased")
        check(OEDataFolderSetup.rebasedPath("/Volumes/External Saves", from: oldRoot, to: newRoot) == nil,
              "explicit external path stays unchanged")
        check(OEDataFolderSetup.rebasedPath(oldRoot + " Other/Game Library", from: oldRoot, to: newRoot) == nil,
              "similar path prefix is not treated as internal")
        check(OEDataFolderSetup.rebasedPath(URL(fileURLWithPath: "/Volumes/External Saves").absoluteString, from: oldRoot, to: newRoot) == nil,
              "external file URL stays unchanged")

        let standardLegacyRoot = "/Users/Example/Library/Application Support/OpenEmu"
        let adoptedRoot = "/Volumes/Games/OpenEmu"
        let imported = OEDataFolderSetup.migratedLegacySettings([
            "databasePath": standardLegacyRoot + "/Game Library",
            "defaultDatabasePath": standardLegacyRoot + "/Game Library",
            "saveStateFolder": URL(fileURLWithPath: standardLegacyRoot + "/Save States").absoluteString,
            "screenshotFolder": "/Volumes/External Screenshots",
            "OEBackupFolderPath": standardLegacyRoot + "/Backups",
            "NSWindow Frame Main": "system state",
            "SUEnableAutomaticChecks": true,
            "OEDataFolderPath": "/stale/bootstrap",
            "region": 2
        ], from: standardLegacyRoot, to: adoptedRoot)
        check(imported["databasePath"] as? String == adoptedRoot + "/Game Library" && imported["defaultDatabasePath"] as? String == adoptedRoot + "/Game Library",
              "first-time legacy import rebases internal database paths without a prior root marker")
        check(imported["saveStateFolder"] as? String == URL(fileURLWithPath: adoptedRoot + "/Save States").absoluteString,
              "first-time legacy import rebases internal file URLs")
        check(imported["screenshotFolder"] as? String == "/Volumes/External Screenshots" && imported["OEBackupFolderPath"] as? String == adoptedRoot + "/Backups",
              "legacy import rebases internal backup but preserves explicitly external screenshots")
        check(imported["NSWindow Frame Main"] == nil && imported["SUEnableAutomaticChecks"] == nil && imported["OEDataFolderPath"] == nil && imported["region"] as? Int == 2,
              "legacy import excludes system/bootstrap preferences and preserves app settings")
        let customLibrary = OEDataFolderSetup.migratedLegacySettings(["databasePath": "/Volumes/Custom Library"], from: standardLegacyRoot, to: adoptedRoot)
        check(customLibrary["databasePath"] as? String == "/Volumes/Custom Library", "legacy import does not infer or move an unrelated custom library")

        let releaseLegacy: [String: Any] = ["region": 2, "databasePath": standardLegacyRoot + "/Game Library"]
        let debugLegacy: [String: Any] = ["region": 3, "NSWindow Frame Main": "system state"]
        let combinedLegacy = OEDataFolderSetup.combinedLegacySettings(release: releaseLegacy, active: debugLegacy)
        let debugImport = OEDataFolderSetup.migratedLegacySettings(combinedLegacy, from: standardLegacyRoot, to: adoptedRoot)
        check(debugImport["region"] as? Int == 3 && debugImport["databasePath"] as? String == adoptedRoot + "/Game Library",
              "Debug adopts Release legacy settings while retaining its own explicit overrides")
        check(debugImport["NSWindow Frame Main"] == nil,
              "combined legacy domains still exclude framework settings")
        check(OEDataFolderSetup.combinedLegacySettings(release: releaseLegacy, active: [:])["region"] as? Int == 2,
              "first Debug launch does not lose old Release settings")

        let preferencesRoot = try directory("bindings-profile")
        let preferencesIdentity = try OEDataFolderIdentity.prepare(at: preferencesRoot)
        try OEPreferences.configure(url: preferencesRoot.appendingPathComponent("Settings.plist"), readOnly: false)
        let preferences = OEPreferences.shared
        preferences.register(defaults: ["controlFlag": false])
        let controller = OEPreferencesController.shared
        DispatchQueue.concurrentPerform(iterations: 16) { @Sendable _ in
            let concurrentController = OEPreferencesController.shared
            check(concurrentController === controller && concurrentController.values === preferences
                  && !concurrentController.values.bool(forKey: "controlFlag"),
                  "immutable Cocoa adapter supports nonisolated concurrent access")
        }
        let observer = BindingObserver()
        controller.addObserver(observer, forKeyPath: "values.controlFlag", options: [.old, .new], context: nil)
        preferences.set(true, forKey: "controlFlag")
        check(observer.changes == 1 && observer.previous as? Bool == false && observer.next as? Bool == true,
              "Cocoa values adapter forwards direct writer KVO")
        controller.setValue(false, forKeyPath: "values.controlFlag")
        check(observer.changes == 2 && preferences.bool(forKey: "controlFlag") == false,
              "Cocoa key-path setter writes file-backed preferences (changes: \(observer.changes), value: \(preferences.bool(forKey: "controlFlag")))")
        controller.removeObserver(observer, forKeyPath: "values.controlFlag")

        let button = NSButton(checkboxWithTitle: "Storage Test", target: nil, action: nil)
        button.bind(.value, to: controller, withKeyPath: "values.controlFlag", options: nil)
        check(button.state == .off, "bound checkbox reads initial setting")
        preferences.set(true, forKey: "controlFlag")
        check(button.state == .on, "bound checkbox sees file-backed setting changes")
        button.performClick(nil)
        check(button.state == .off && !preferences.bool(forKey: "controlFlag"),
              "clicking the bound checkbox updates file-backed preferences")
        let clickedSettings = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: preferencesRoot.appendingPathComponent("Settings.plist")),
            options: [], format: nil) as? [String: Any]
        check(clickedSettings?["controlFlag"] as? Bool == false,
              "clicked checkbox value is persisted in Settings.plist")
        button.unbind(.value)
        check(preferences.synchronize(), "settings changes are persisted")

        // Reset fixtures never use the actual data folder or macOS app domain.
        let settingsURL = preferencesRoot.appendingPathComponent("Settings.plist")
        let settingsBeforeReset = try Data(contentsOf: settingsURL)
        let bindingsFolder = preferencesRoot.appendingPathComponent("Bindings", isDirectory: true)
        try fm.createDirectory(at: bindingsFolder, withIntermediateDirectories: false)
        let bindingsFile = bindingsFolder.appendingPathComponent("Default.oebindings")
        let credentialsFile = preferencesRoot.appendingPathComponent(".oe_credentials")
        let oldBindings = Data("old controller mappings".utf8)
        let oldCredentials = Data("fixture credentials, not a real account".utf8)
        let emptyCredentials = Data("fixture encrypted empty store".utf8)
        try oldBindings.write(to: bindingsFile)
        try oldCredentials.write(to: credentialsFile)
        let retained = ["Game Library/Library.storedata", "BIOS/test.bin", "Save States/test.oesavestate",
                        "Cores/test.oecoreplugin", "Shaders/custom.slangp", "Bindings/notes.txt"]
        for path in retained {
            let url = preferencesRoot.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("must be retained".utf8).write(to: url)
        }

        expectFailure("failure of the final preferences commit must abort reset") {
            try OEDataFolderSettingsReset.perform(at: preferencesRoot, emptyCredentials: emptyCredentials, validateRoot: {}) {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        check(try Data(contentsOf: bindingsFile) == oldBindings, "failed reset restores bindings")
        check(try Data(contentsOf: credentialsFile) == oldCredentials, "failed reset restores credentials")
        check(try Data(contentsOf: settingsURL) == settingsBeforeReset && !preferences.isResettingForTermination,
              "failed reset leaves settings and normal writes unchanged")
        expectFailure("changed data root must be rejected before the first write") {
            try OEDataFolderSettingsReset.perform(at: preferencesRoot, emptyCredentials: emptyCredentials,
                                                 validateRoot: { throw CocoaError(.fileReadInvalidFileName) }) {
                check(false, "changed root must not reach the preferences commit")
            }
        }
        check(try Data(contentsOf: credentialsFile) == oldCredentials && Data(contentsOf: bindingsFile) == oldBindings,
              "root validation failure changes no files")
        try fm.removeItem(at: credentialsFile)
        expectFailure("failed reset must restore an originally absent credential store") {
            try OEDataFolderSettingsReset.perform(at: preferencesRoot, emptyCredentials: emptyCredentials, validateRoot: {}) {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        check(!fm.fileExists(atPath: credentialsFile.path), "rollback removes only the new empty credential fixture")
        try oldCredentials.write(to: credentialsFile)

        let external = workspace.appendingPathComponent("external-bindings")
        try Data("do not follow this link".utf8).write(to: external)
        let linkedBindings = bindingsFolder.appendingPathComponent("Linked.oebindings")
        try fm.createSymbolicLink(at: linkedBindings, withDestinationURL: external)
        expectFailure("linked settings files must be rejected before writing") {
            try OEDataFolderSettingsReset.perform(at: preferencesRoot, emptyCredentials: emptyCredentials, validateRoot: {}) {
                check(false, "invalid target must not reach the preferences commit")
            }
        }
        check(try Data(contentsOf: external) == Data("do not follow this link".utf8), "external link target is untouched")
        check(try Data(contentsOf: credentialsFile) == oldCredentials, "preflight failure does not change credentials")
        try fm.removeItem(at: linkedBindings)

        preferences.set(true, forKey: "setupAssistantFinished")
        try OEDataFolderSettingsReset.perform(at: preferencesRoot, emptyCredentials: emptyCredentials, validateRoot: {}) {
            try preferences.resetForTermination()
        }
        let resetSettings = try PropertyListSerialization.propertyList(from: Data(contentsOf: settingsURL), format: nil) as? [String: Any]
        let resetBindings = try PropertyListSerialization.propertyList(from: Data(contentsOf: bindingsFile), format: nil) as? [String: Any]
        check(resetSettings?.isEmpty == true && resetBindings?.isEmpty == true, "all persisted preferences and mappings are empty")
        check(try Data(contentsOf: credentialsFile) == emptyCredentials, "credential transaction writes only supplied empty store")
        preferences.set(true, forKey: "setupAssistantFinished")
        check(try Data(contentsOf: settingsURL) == PropertyListSerialization.data(fromPropertyList: [String: String](), format: .binary, options: 0),
              "late termination writes cannot finish setup again")
        check(try OEDataFolderIdentity.read(at: preferencesRoot) == preferencesIdentity, "reset preserves data-folder identity")
        check(fm.fileExists(atPath: settingsURL.appendingPathExtension("lock").path), "reset preserves settings-writer lock file")
        for path in retained {
            check(try Data(contentsOf: preferencesRoot.appendingPathComponent(path)) == Data("must be retained".utf8),
                  "reset does not alter user asset: \(path)")
        }
        print("PASS: data-folder identity, path rebasing, concurrent Cocoa adapter access, KVO and checkbox binding")
        print("PASS: settings reset, rollback, link rejection, late-write suppression and game-data preservation")
    }
}
