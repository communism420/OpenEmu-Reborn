// Copyright (c) 2021, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation
import OpenEmuBase
import OpenEmuKit
import Sparkle.SUStandardVersionComparator
import OSLog

final class CoreUpdater: NSObject {

    // Each CPU has its own complete Reborn catalog. Plugin-embedded legacy
    // feed URLs cannot override the application's pinned publisher key.
    private static var coreListURL: URL? { OECoreUpdateSecurity.catalogURL() }
    
    enum Errors: LocalizedError {
        case noDownloadableCoreForIdentifierError
        case newCoreCheckAlreadyPendingError

        var errorDescription: String? {
            switch self {
            case .noDownloadableCoreForIdentifierError:
                NSLocalizedString("No compatible, verified download is available for this core. Check for updates again.", comment: "")
            case .newCoreCheckAlreadyPendingError:
                NSLocalizedString("A core update check is already in progress.", comment: "")
            }
        }
    }
    
    static let shared = CoreUpdater()
    
    @objc dynamic private(set) var coreList: [CoreDownload] = []
    
    var completionHandler: ((_ plugin: OECorePlugin?, Error?) -> Void)?
    var coreIdentifier: String?
    var alert: OEAlert?
    var coreDownload: CoreDownload?
    
    private var coresDict: [String : CoreDownload] = [:]
    private var autoInstall = false
    private var lastCoreListURLTask: URLSessionDataTask?
    private var pendingCoreListCompletionHandlers: [(_ error: Error?) -> Void] = []
    private var pendingUserInitiatedDownloads: Set<CoreDownload> = []
    private var coreListCheckID: UUID?
    
    // Backup directory
    private var coresDirectory: URL {
        URL.oeApplicationSupportDirectory.appendingPathComponent("Cores", isDirectory: true)
    }
    
    override init() {
        super.init()
        
        for plugin in OECorePlugin.allPlugins {
            let download = CoreDownload(plugin: plugin)
            download.delegate = self
            let bundleID = plugin.bundleIdentifier.lowercased()
            coresDict[bundleID] = download
        }
        
        updateCoreList()
    }
    
    private func updateCoreList() {
        willChangeValue(forKey: #keyPath(coreList))
        coreList = coresDict.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        didChangeValue(forKey: #keyPath(coreList))
    }
    
    @objc func checkForUpdates() {
        checkForNewCores()
    }
    
    func checkForUpdatesAndInstall() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.checkForUpdatesAndInstall() }
            return
        }
        if let val = ProcessInfo.processInfo.environment["OE_DISABLE_UPDATE_CHECK"] as? NSString, val.boolValue {
            if #available(macOS 11.0, *) {
                Logger.download.info("OE_DISABLE_UPDATE_CHECK found; skipping check for updates.")
            }
            return
        }
        autoInstall = true
        checkForUpdates()
    }
    
    func checkForNewCores(completionHandler handler: ((_ error: Error?) -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.checkForNewCores(completionHandler: handler) }
            return
        }
        if let handler { pendingCoreListCompletionHandlers.append(handler) }
        guard coreListCheckID == nil else { return }
        let checkID = UUID()
        coreListCheckID = checkID
        // A failed/withdrawn feed must not leave an old Install/Update action
        // enabled. In-flight downloads own an immutable offer and are untouched.
        for download in coresDict.values where !download.requiresRestart && !download.hasActiveInstallation {
            download.appcastItem = nil
            download.hasUpdate = false
        }
        updateCoreList()
        guard let catalogURL = Self.coreListURL,
              OECoreUpdateSecurity.publicKey(for: catalogURL) != nil else {
            finishCoreListCheck(checkID, error: OECoreUpdateSecurity.ValidationError.untrustedFeed)
            return
        }
        var request = URLRequest(url: catalogURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        lastCoreListURLTask = URLSession.oeShared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard self.coreListCheckID == checkID else { return }
                do {
                    if let error { throw error }
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                          let finalURL = http.url, OECoreUpdateSecurity.publicKey(for: finalURL) != nil, let data else {
                        throw OECoreUpdateSecurity.ValidationError.badResponse
                    }
                    let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
                    guard let root = document.rootElement(), root.name == "cores",
                          root.attribute(forName: "architecture")?.stringValue == OECoreUpdateSecurity.runningArchitecture,
                          let nodes = try document.nodes(forXPath: "/cores/core") as? [XMLElement], !nodes.isEmpty else {
                        throw OECoreUpdateSecurity.ValidationError.invalidMetadata
                    }
                    var identifiers = Set<String>()
                    var entries: [(id: String, name: String, url: URL, systems: [(String, String)])] = []
                    for node in nodes {
                        guard let identifier = node.attribute(forName: "id")?.stringValue?.lowercased(), !identifier.isEmpty,
                              identifiers.insert(identifier).inserted,
                              let name = node.attribute(forName: "name")?.stringValue, !name.isEmpty,
                              let location = node.attribute(forName: "appcastURL")?.stringValue,
                              let url = URL(string: location), OECoreUpdateSecurity.publicKey(for: url) != nil,
                              let systems = try node.nodes(forXPath: "./systems/system") as? [XMLElement], !systems.isEmpty else {
                            throw OECoreUpdateSecurity.ValidationError.invalidMetadata
                        }
                        let systemInfo = try systems.map { system -> (String, String) in
                            guard let id = system.attribute(forName: "id")?.stringValue, !id.isEmpty,
                                  let title = system.stringValue, !title.isEmpty else {
                                throw OECoreUpdateSecurity.ValidationError.invalidMetadata
                            }
                            return (id, title)
                        }
                        entries.append((identifier, name, url, systemInfo))
                    }
                    let group = DispatchGroup()
                    var firstError: Error?
                    for entry in entries {
                        let existing = self.coresDict[entry.id]
                        guard existing?.requiresRestart != true, existing?.hasActiveInstallation != true else { continue }
                        group.enter()
                        CoreAppcast(url: entry.url).fetch { result in
                            defer { group.leave() }
                            guard self.coreListCheckID == checkID else { return }
                            switch result {
                            case .failure(let error):
                                firstError = firstError ?? error
                            case .success(let items):
                                // Items are sorted by version, not by mutable feed order.
                                let item = items.first(where: { $0.isSupported })
                                if let existing {
                                    guard !existing.requiresRestart, !existing.hasActiveInstallation else { return }
                                    if existing.canBeInstalled {
                                        // A previously discovered, still unselected core is
                                        // not an installed core with an old/empty version.
                                        existing.appcastItem = item
                                        existing.hasUpdate = false
                                    } else {
                                        existing.hasUpdate = item.map {
                                            SUStandardVersionComparator.default.compareVersion($0.version, toVersion: existing.version) == .orderedDescending
                                        } ?? false
                                        existing.appcastItem = existing.hasUpdate ? item : nil
                                        if self.autoInstall && existing.hasUpdate { existing.start() }
                                    }
                                } else if let item {
                                    let download = CoreDownload()
                                    download.name = entry.name
                                    download.bundleIdentifier = entry.id
                                    download.systemIdentifiers = entry.systems.map { $0.0 }
                                    download.systemNames = entry.systems.map { $0.1 }
                                    download.canBeInstalled = true
                                    download.appcastItem = item
                                    download.delegate = self
                                    self.coresDict[entry.id] = download
                                    if download == self.coreDownload { download.start() }
                                }
                            }
                        }
                    }
                    group.notify(queue: .main) {
                        self.finishCoreListCheck(checkID, error: firstError)
                    }
                } catch {
                    self.finishCoreListCheck(checkID, error: error)
                }
            }
        }
        lastCoreListURLTask?.resume()
    }

    private func finishCoreListCheck(_ checkID: UUID, error: Error?) {
        guard coreListCheckID == checkID else { return }
        coreListCheckID = nil
        lastCoreListURLTask = nil
        updateCoreList()
        let handlers = pendingCoreListCompletionHandlers
        pendingCoreListCompletionHandlers.removeAll()
        if let error { Logger.download.error("Core update check failed: \(error.localizedDescription, privacy: .public)") }
        handlers.forEach { $0(error) }
    }

    func cancelCheckForNewCores() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.cancelCheckForNewCores() }
            return
        }
        guard let checkID = coreListCheckID else { return }
        lastCoreListURLTask?.cancel()
        finishCoreListCheck(checkID, error: URLError(.cancelled))
    }
    
    // MARK: - Installing with OEAlert
    
    func installCore(for game: OEDBGame, withCompletionHandler handler: @escaping (_ plugin: OECorePlugin?, _ error: Error?) -> Void) {
        
        let systemIdentifier = game.system?.systemIdentifier ?? ""
        var validPlugins = coreList.filter { $0.systemIdentifiers.contains(systemIdentifier) }
        
        if !validPlugins.isEmpty {
            let download: CoreDownload
            
            if validPlugins.count == 1 {
                download = validPlugins.first!
            } else {
                // Sort by core name alphabetically to match our automatic core picker behavior
                validPlugins.sort {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                
                // Check if a core is set as default in AppDelegate
                var defaultCore: CoreDownload?
                let key = "defaultCore.\(systemIdentifier)"
                if let defaultCoreID = OEPreferences.shared.string(forKey: key) {
                    defaultCore = validPlugins.first(where: { defaultCoreID.caseInsensitiveCompare($0.bundleIdentifier) == .orderedSame })
                }
                
                // Use default core plugin for this system, otherwise just use first found from the sorted list
                if let defaultCore {
                    download = defaultCore
                } else {
                    download = validPlugins.first!
                }
            }
            
            let coreName = download.name
            let message = String(format: NSLocalizedString("OpenEmu uses 'Cores' to emulate games. You need the %@ Core to play %@", comment: ""), coreName, game.displayName)
            installCore(with: download, message: message, completionHandler: handler)
        }
        else {
            handler(nil, Errors.noDownloadableCoreForIdentifierError)
        }
    }
    
    func installCore(for state: OEDBSaveState, withCompletionHandler handler: @escaping (_ plugin: OECorePlugin?, _ error: Error?) -> Void) {
        
        let coreID = state.coreIdentifier.lowercased()
        if let download = coresDict[coreID] {
            let coreName = download.name
            let message = String(format: NSLocalizedString("To launch the save state %@ you will need to install the '%@' Core", comment: ""), state.displayName, coreName)
            installCore(with: download, message: message, completionHandler: handler)
        } else {
            // TODO: create proper error saying that no core is available for the state
            handler(nil, Errors.noDownloadableCoreForIdentifierError)
        }
    }
    
    func installCore(with download: CoreDownload, message: String, completionHandler handler: @escaping (_ plugin: OECorePlugin?, _ error: Error?) -> Void) {
        
        let alert = OEAlert()
        alert.messageText = NSLocalizedString("Missing Core", comment: "")
        alert.informativeText = message
        alert.defaultButtonTitle = NSLocalizedString("Install", comment: "")
        alert.alternateButtonTitle = NSLocalizedString("Cancel", comment: "")
        alert.setDefaultButtonAction(#selector(startInstall), andTarget: self)
        
        coreIdentifier = coresDict.first(where: { $1 == download })?.key
        completionHandler = handler
        
        self.alert = alert
        
        if alert.runModal() == .alertSecondButtonReturn {
            handler(nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        
        completionHandler = nil
        coreDownload = nil
        coreIdentifier = nil
        
        self.alert = nil
    }
    
    func installCore(with download: CoreDownload, completionHandler handler: @escaping (_ plugin: OECorePlugin?, _ error: Error?) -> Void) {
        
        let alert = OEAlert()
        
        coreIdentifier = coresDict.first(where: { $1 == download })?.key
        completionHandler = handler
        self.alert = alert
        
        alert.performBlockInModalSession {
            self.startInstall()
        }
        alert.runModal()
        
        completionHandler = nil
        coreDownload = nil
        coreIdentifier = nil
        
        self.alert = nil
    }
    
    // MARK: -
    
    func revertCore(bundleID: String, completionHandler: @escaping (Error?) -> Void) {
        let fileManager = FileManager.default
        let backupURL = coresDirectory.appendingPathComponent("\(bundleID).oecoreplugin.bak")
        
        guard let download = coresDict[bundleID.lowercased()],
              !download.requiresRestart, !download.hasActiveInstallation,
              let plugin = OECorePlugin.corePlugin(bundleIdentifier: bundleID),
              plugin.url.deletingLastPathComponent().standardizedFileURL == coresDirectory.standardizedFileURL,
              fileManager.fileExists(atPath: backupURL.path) else {
            completionHandler(NSError(domain: "OpenEmu", code: 404, userInfo: [NSLocalizedDescriptionKey: "No backup found"]))
            return
        }
        
        do {
            let backupInfoData = try Data(contentsOf: backupURL.appendingPathComponent("Contents/Info.plist"))
            guard let backupInfo = try PropertyListSerialization.propertyList(from: backupInfoData, format: nil) as? [String: Any],
                  let backupIdentifier = backupInfo["CFBundleIdentifier"] as? String,
                  backupIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame,
                  let backupVersion = backupInfo["CFBundleVersion"] as? String, !backupVersion.isEmpty else {
                throw NSError(
                    domain: "OpenEmu",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "The core backup has an unexpected bundle identifier."]
                )
            }
            try CoreDownload.validateRunningArchitecture(of: backupURL)

            // The core's product name and bundle identifier are not always the
            // same, so replace the plugin at its real installed URL.
            _ = try fileManager.replaceItemAt(plugin.url, withItemAt: backupURL)
            // A rollback also changes code on disk. Keep live controllers and
            // metadata untouched until restart, just as for a normal update.
            download.markInstallationPendingRestart(version: backupVersion, at: plugin.url)
            updateCoreList()
            completionHandler(nil)
            
        } catch {
            completionHandler(error)
        }
    }
    
    func hasBackup(bundleID: String) -> Bool {
        let backupURL = coresDirectory.appendingPathComponent("\(bundleID).oecoreplugin.bak")
        return FileManager.default.fileExists(atPath: backupURL.path)
    }

    @objc func cancelInstall() {
        coreDownload?.cancel()
        completionHandler = nil
        coreDownload = nil
        alert?.close(withResult: .alertSecondButtonReturn)
        alert = nil
        coreIdentifier = nil
    }
    
    @objc func startInstall() {
        alert?.messageText = NSLocalizedString("Downloading and Installing Core…", comment: "")
        alert?.informativeText = ""
        alert?.defaultButtonTitle = ""
        alert?.setAlternateButtonAction(#selector(cancelInstall), andTarget: self)
        alert?.showsProgressbar = true
        alert?.progress = 0
        
        guard
            let coreID = coreIdentifier,
            let pluginDL = coresDict[coreID],
            pluginDL.appcastItem != nil,
            !pluginDL.requiresRestart,
            !CoreDownload.isDataRemovalPending
        else {
            alert?.messageText = NSLocalizedString("Error!", comment: "")
            alert?.informativeText = NSLocalizedString("The core could not be downloaded. Try installing it from the Cores preferences.", comment: "")
            alert?.defaultButtonTitle = NSLocalizedString("OK", comment: "")
            alert?.alternateButtonTitle = ""
            alert?.setDefaultButtonAction(#selector(OEAlert.buttonAction(_:)), andTarget: alert)
            alert?.showsProgressbar = false
            
            return
        }
        
        coreDownload = pluginDL
        
        coreDownload?.start()
    }
    
    func failInstallWithError(_ error: Error?) {
        alert?.close(withResult: .alertFirstButtonReturn)
        
        completionHandler?(OECorePlugin.corePlugin(bundleIdentifier: coreIdentifier!), error)
        
        alert = nil
        coreIdentifier = nil
        completionHandler = nil
    }
    
    func finishInstall() {
        alert?.close(withResult: .alertFirstButtonReturn)
        
        completionHandler?(OECorePlugin.corePlugin(bundleIdentifier: coreIdentifier!), nil)
        
        alert = nil
        coreIdentifier = nil
        completionHandler = nil
    }
    
    // MARK: - Other user-initiated (= with error reporting) downloads
    
    func installCoreInBackgroundUserInitiated(_ download: CoreDownload) {
        assert(download.delegate === self, "download \(download)'s delegate is not the singleton CoreUpdater!?")

        guard !CoreDownload.isDataRemovalPending else { return }
        guard download.appcastItem != nil, !download.requiresRestart else {
            NSApp.presentError(Errors.noDownloadableCoreForIdentifierError)
            return
        }
        guard !download.hasActiveInstallation else { return }
        
        pendingUserInitiatedDownloads.insert(download)
        
        download.start()
    }
}

// MARK: - CoreDownload Delegate

private var CoreDownloadProgressContext = 0

extension CoreUpdater: CoreDownloadDelegate {
    
    func coreDownloadDidStart(_ download: CoreDownload) {
        updateCoreList()
        
        download.addObserver(self, forKeyPath: #keyPath(CoreDownload.progress), options: [.new, .old, .initial, .prior], context: &CoreDownloadProgressContext)
    }
    
    func coreDownloadDidFinish(_ download: CoreDownload) {
        updateCoreList()
        
        download.removeObserver(self, forKeyPath: #keyPath(CoreDownload.progress), context: &CoreDownloadProgressContext)
        
        if download == coreDownload {
            finishInstall()
        }
        
        pendingUserInitiatedDownloads.remove(download)
    }
    
    func coreDownloadDidFail(_ download: CoreDownload, withError error: Error?) {
        updateCoreList()

        download.removeObserver(self, forKeyPath: #keyPath(CoreDownload.progress), context: &CoreDownloadProgressContext)
        
        if download == coreDownload {
            failInstallWithError(error)
        }
        
        if pendingUserInitiatedDownloads.contains(download),
           let error = error {
            NSApp.presentError(error)
        }
        
        pendingUserInitiatedDownloads.remove(download)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        guard context == &CoreDownloadProgressContext else {
            return super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
        
        if let object = object as? CoreDownload,
           object == coreDownload {
            alert?.progress = coreDownload!.progress
        }
    }
}

private final class CoreAppcast {
    let url: URL

    init(url: URL) { self.url = url }

    func fetch(completionHandler handler: @escaping (Result<[CoreAppcastItem], Error>) -> Void) {
        guard let publicKey = OECoreUpdateSecurity.publicKey(for: url) else {
            handler(.failure(OECoreUpdateSecurity.ValidationError.untrustedFeed))
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let task = URLSession.oeShared.dataTask(with: request) { data, response, error in
            let result: Result<[CoreAppcastItem], Error> = Result {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let finalURL = http.url,
                      OECoreUpdateSecurity.publicKey(for: finalURL) == publicKey, let data else {
                    throw OECoreUpdateSecurity.ValidationError.badResponse
                }
                return try CoreAppcastItem.parse(data, publicKey: publicKey)
            }
            DispatchQueue.main.async { handler(result) }
        }
        task.resume()
    }
}
