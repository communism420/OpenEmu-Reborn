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
import OpenEmuKit

final class CoreDownload: NSObject {
    
    weak var delegate: CoreDownloadDelegate?
    
    var name = ""
    var systemIdentifiers: [String] = []
    var systemNames: [String] = []
    var version = ""
    var bundleIdentifier = ""
    
    var hasUpdate = false
    var canBeInstalled = false
    
    private(set) var isDownloading = false
    @objc private(set) dynamic var progress: Double = 0
    
    var appcastItem: CoreAppcastItem?
    
    private var downloadSession: URLSession?
    private var pendingFinish = false
    private var didReportCompletion = false
    private var cancellationRequested = false
    private var activeInstallPipeline: UUID?
    private weak var installedPlugin: OECorePlugin?
    private var installedPluginURL: URL?
    
    convenience init(plugin: OECorePlugin) {
        self.init()
        updateProperties(with: plugin)
    }
    
    func start() {
        guard let appcastItem = appcastItem,
              !isDownloading,
              downloadSession == nil,
              activeInstallPipeline == nil else { return }
        
        assert(downloadSession == nil, "There shouldn't be a previous download session.")
        
        let downloadSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadSession.sessionDescription = bundleIdentifier
        self.downloadSession = downloadSession
        pendingFinish = false
        didReportCompletion = false
        cancellationRequested = false
        
        let downloadTask = downloadSession.downloadTask(with: appcastItem.fileURL)
        
        DLog("Starting core download (\(downloadSession.sessionDescription ?? ""))")
        
        downloadTask.resume()
        
        isDownloading = true
        delegate?.coreDownloadDidStart(self)
    }
    
    func cancel() {
        DLog("Cancelling core download (\(downloadSession?.sessionDescription ?? ""))")
        cancellationRequested = true
        downloadSession?.invalidateAndCancel()
    }
    
    private func updateProperties(with plugin: OECorePlugin) {
        installedPlugin = plugin
        installedPluginURL = plugin.url
        name = plugin.displayName
        version = plugin.version
        hasUpdate = false
        canBeInstalled = false
        
        var systemNames: [String] = []
        for systemIdentifier in plugin.systemIdentifiers {
            if let plugin = OESystemPlugin.systemPlugin(forIdentifier: systemIdentifier) {
               let systemName = plugin.systemName
                systemNames.append(systemName)
            }
        }
        
        self.systemNames = systemNames
        systemIdentifiers = plugin.systemIdentifiers
        bundleIdentifier = plugin.bundleIdentifier
    }
}

extension CoreDownload: URLSessionDownloadDelegate {
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        
        DLog("Core download (\(session.sessionDescription ?? "")) did complete: \(error?.localizedDescription ?? "no errors")")
        
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        
        if let error {
            cancellationRequested = true
            reportFailure(error)
        } else if !pendingFinish && !didReportCompletion {
            // A successful URLSession completion must have handed the download to
            // the validation/install pipeline in didFinishDownloadingTo.
            reportFailure(CoreDownloadError.missingDownloadedArchive)
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        
        progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        DLog("Core download (\(session.sessionDescription ?? "")) did finish downloading temporary data.")
        
        let coresFolder = URL.oeApplicationSupportDirectory
            .appendingPathComponent("Cores", isDirectory: true)
        pendingFinish = true
        let pipelineID = UUID()
        activeInstallPipeline = pipelineID

        let fileManager = FileManager.default
        let stagingDirectory = coresFolder.appendingPathComponent(".CoreDownload-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: coresFolder, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)

            guard ArchiveHelper.decompressFileInArchive(at: location, toDirectory: stagingDirectory) != nil else {
                throw CoreDownloadError.invalidArchive
            }

            let pluginURL = try validatedPlugin(in: stagingDirectory)

            adHocSign(pluginURL) { result in
                switch result {
                case .failure(let error):
                    try? fileManager.removeItem(at: stagingDirectory)
                    guard self.activeInstallPipeline == pipelineID else { return }
                    self.finishInstallPipeline(pipelineID)
                    self.reportFailure(error)

                case .success:
                    guard self.activeInstallPipeline == pipelineID else {
                        try? fileManager.removeItem(at: stagingDirectory)
                        return
                    }
                    guard !self.didReportCompletion else {
                        try? fileManager.removeItem(at: stagingDirectory)
                        self.finishInstallPipeline(pipelineID)
                        return
                    }
                    guard !self.cancellationRequested else {
                        try? fileManager.removeItem(at: stagingDirectory)
                        self.finishInstallPipeline(pipelineID)
                        self.reportFailure(URLError(.cancelled))
                        return
                    }
                    var transaction: InstallationTransaction?
                    do {
                        let completedTransaction = try self.install(pluginURL, from: stagingDirectory, into: coresFolder)
                        transaction = completedTransaction
                        let plugin = try self.loadInstalledPlugin(at: completedTransaction.destinationURL)

                        if self.hasUpdate {
                            guard plugin.version == self.appcastItem?.version else {
                                throw CoreDownloadError.installedVersionMismatch(
                                    expected: self.appcastItem?.version ?? "",
                                    actual: plugin.version
                                )
                            }
                            self.version = plugin.version
                            self.hasUpdate = false
                            self.canBeInstalled = false
                            self.installedPluginURL = completedTransaction.destinationURL
                        } else if self.canBeInstalled {
                            self.updateProperties(with: plugin)
                        }

                        try? fileManager.removeItem(at: stagingDirectory)
                        self.finishInstallPipeline(pipelineID)
                        DLog("Core (\(self.bundleIdentifier)) installed after bundle and architecture validation.")
                        self.reportSuccess()
                    } catch {
                        if let transaction {
                            self.rollback(transaction, stagingDirectory: stagingDirectory)
                        }
                        try? fileManager.removeItem(at: stagingDirectory)
                        self.finishInstallPipeline(pipelineID)
                        self.reportFailure(error)
                    }
                }
            }
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            finishInstallPipeline(pipelineID)
            reportFailure(error)
        }
    }
}

// MARK: - Validation and installation

extension CoreDownload {

    /// Validates every executable object and static archive in a core bundle
    /// against the architecture of the running OpenEmu process.
    static func validateRunningArchitecture(of pluginURL: URL) throws {
        try validatePluginArchitecture(pluginURL)
    }
}

private extension CoreDownload {

    struct InstallationTransaction {
        let destinationURL: URL
        let backupURL: URL?
        let replacedExistingCore: Bool
    }

    static var runningArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
#error("Core downloads are only supported for arm64 and x86_64 builds.")
#endif
    }

    func validatedPlugin(in stagingDirectory: URL) throws -> URL {
        let fileManager = FileManager.default
        var stagingEnumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                stagingEnumerationError = error
                return false
            }
        ) else {
            throw CoreDownloadError.cannotInspectArchive
        }

        var pluginURLs: [URL] = []
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                throw CoreDownloadError.cannotInspectFile(url.lastPathComponent, error)
            }

            if values.isSymbolicLink == true {
                let resolvedURL = url.resolvingSymlinksInPath()
                guard Self.isDescendant(resolvedURL, of: stagingDirectory) else {
                    throw CoreDownloadError.unsafeSymbolicLink(url.lastPathComponent)
                }
            }

            if values.isDirectory == true,
               url.pathExtension.caseInsensitiveCompare(OECorePlugin.pluginExtension) == .orderedSame {
                guard values.isSymbolicLink != true else {
                    throw CoreDownloadError.unsafeSymbolicLink(url.lastPathComponent)
                }
                pluginURLs.append(url)
            }
        }

        if let stagingEnumerationError {
            throw CoreDownloadError.cannotInspectFile(stagingDirectory.lastPathComponent, stagingEnumerationError)
        }

        guard pluginURLs.count == 1, let pluginURL = pluginURLs.first else {
            throw CoreDownloadError.unexpectedPluginCount(pluginURLs.count)
        }

        let resolvedPluginURL = pluginURL.resolvingSymlinksInPath()
        guard Self.isDescendant(resolvedPluginURL, of: stagingDirectory) else {
            throw CoreDownloadError.pluginOutsideStagingDirectory
        }

        guard let bundle = Bundle(url: pluginURL),
              let infoDictionary = bundle.infoDictionary,
              let actualBundleIdentifier = infoDictionary["CFBundleIdentifier"] as? String,
              !actualBundleIdentifier.isEmpty,
              let actualVersion = infoDictionary["CFBundleVersion"] as? String,
              !actualVersion.isEmpty
        else {
            throw CoreDownloadError.invalidPluginBundle
        }

        guard !bundleIdentifier.isEmpty,
              actualBundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame else {
            throw CoreDownloadError.bundleIdentifierMismatch(
                expected: bundleIdentifier,
                actual: actualBundleIdentifier
            )
        }

        guard let expectedVersion = appcastItem?.version, !expectedVersion.isEmpty,
              actualVersion == expectedVersion else {
            throw CoreDownloadError.bundleVersionMismatch(
                expected: appcastItem?.version ?? "",
                actual: actualVersion
            )
        }

        try Self.validatePluginArchitecture(pluginURL)
        return pluginURL
    }

    static func validatePluginArchitecture(_ pluginURL: URL) throws {
        let fileManager = FileManager.default
        let pluginValues = try pluginURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard pluginValues.isDirectory == true, pluginValues.isSymbolicLink != true else {
            throw CoreDownloadError.unsafeInstallDestination
        }
        guard let bundle = Bundle(url: pluginURL), let executableURL = bundle.executableURL else {
            throw CoreDownloadError.missingExecutable
        }

        let resolvedExecutableURL = executableURL.resolvingSymlinksInPath()
        guard Self.isDescendant(resolvedExecutableURL, of: pluginURL),
              fileManager.fileExists(atPath: resolvedExecutableURL.path) else {
            throw CoreDownloadError.missingExecutable
        }

        var inspectedBinaryPaths = Set<String>()
        try verifyBinary(at: resolvedExecutableURL, relativeTo: pluginURL, requireBinary: true)
        inspectedBinaryPaths.insert(resolvedExecutableURL.standardizedFileURL.path)

        var bundleEnumerationError: Error?
        guard let bundleEnumerator = fileManager.enumerator(
            at: pluginURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                bundleEnumerationError = error
                return false
            }
        ) else {
            throw CoreDownloadError.cannotInspectArchive
        }

        for case let url as URL in bundleEnumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            } catch {
                throw CoreDownloadError.cannotInspectFile(url.lastPathComponent, error)
            }

            if values.isSymbolicLink == true {
                let resolvedURL = url.resolvingSymlinksInPath()
                guard Self.isDescendant(resolvedURL, of: pluginURL) else {
                    throw CoreDownloadError.unsafeSymbolicLink(url.lastPathComponent)
                }
                continue
            }

            guard values.isRegularFile == true else { continue }
            let standardizedPath = url.standardizedFileURL.path
            guard inspectedBinaryPaths.insert(standardizedPath).inserted else { continue }
            try verifyBinary(at: url, relativeTo: pluginURL, requireBinary: false)
        }

        if let bundleEnumerationError {
            throw CoreDownloadError.cannotInspectFile(pluginURL.lastPathComponent, bundleEnumerationError)
        }
    }

    static func verifyBinary(at url: URL, relativeTo pluginURL: URL, requireBinary: Bool) throws {
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            header = try handle.read(upToCount: 8) ?? Data()
        } catch {
            throw CoreDownloadError.cannotInspectFile(url.lastPathComponent, error)
        }

        let isBinary = Self.isMachOOrStaticArchive(header)
        if requireBinary && !isBinary {
            throw CoreDownloadError.executableIsNotMachO
        }
        guard isBinary else { return }

        let architectureProcess = Process()
        let outputPipe = Pipe()
        architectureProcess.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        architectureProcess.arguments = ["-archs", url.path]
        architectureProcess.standardOutput = outputPipe
        architectureProcess.standardError = outputPipe

        do {
            try architectureProcess.run()
        } catch {
            throw CoreDownloadError.cannotReadArchitectures(relativePath(of: url, in: pluginURL), error)
        }

        let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
        architectureProcess.waitUntilExit()
        let output = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard architectureProcess.terminationStatus == 0 else {
            throw CoreDownloadError.cannotReadArchitectures(
                relativePath(of: url, in: pluginURL),
                NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(architectureProcess.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: output]
                )
            )
        }

        let architectures = Set(output.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        guard architectures.contains(Self.runningArchitecture) else {
            throw CoreDownloadError.incompatibleBinary(
                relativePath(of: url, in: pluginURL),
                expected: Self.runningArchitecture,
                actual: architectures.sorted().joined(separator: ", ")
            )
        }
    }

    func install(_ pluginURL: URL, from stagingDirectory: URL, into coresFolder: URL) throws -> InstallationTransaction {
        let fileManager = FileManager.default
        let existingCoreURL = try existingCoreURL(in: coresFolder)
        let destinationURL = existingCoreURL ?? coresFolder.appendingPathComponent(pluginURL.lastPathComponent, isDirectory: true)

        guard destinationURL.deletingLastPathComponent().standardizedFileURL == coresFolder.standardizedFileURL else {
            throw CoreDownloadError.unsafeInstallDestination
        }

        if fileManager.fileExists(atPath: destinationURL.path), existingCoreURL == nil {
            let existingIdentifier = Bundle(url: destinationURL)?.bundleIdentifier ?? ""
            throw CoreDownloadError.installDestinationOccupied(destinationURL.lastPathComponent, existingIdentifier)
        }

        guard let existingCoreURL else {
            do {
                try fileManager.moveItem(at: pluginURL, to: destinationURL)
                return InstallationTransaction(
                    destinationURL: destinationURL,
                    backupURL: nil,
                    replacedExistingCore: false
                )
            } catch {
                throw CoreDownloadError.installFailed(error)
            }
        }

        let backupURL = coresFolder.appendingPathComponent("\(bundleIdentifier).oecoreplugin.bak", isDirectory: true)
        guard backupURL.deletingLastPathComponent().standardizedFileURL == coresFolder.standardizedFileURL else {
            throw CoreDownloadError.unsafeInstallDestination
        }
        let stagedBackupURL = stagingDirectory.appendingPathComponent("PreviousCore", isDirectory: true)

        do {
            // Publish a complete backup before touching the live bundle. If the
            // later atomic replacement fails, the live core and this backup are
            // both still usable.
            try fileManager.copyItem(at: existingCoreURL, to: stagedBackupURL)
            if fileManager.fileExists(atPath: backupURL.path) {
                _ = try fileManager.replaceItemAt(backupURL, withItemAt: stagedBackupURL)
            } else {
                try fileManager.moveItem(at: stagedBackupURL, to: backupURL)
            }

            _ = try fileManager.replaceItemAt(existingCoreURL, withItemAt: pluginURL)
            guard fileManager.fileExists(atPath: existingCoreURL.path) else {
                throw CoreDownloadError.installDidNotProduceBundle
            }

            return InstallationTransaction(
                destinationURL: existingCoreURL,
                backupURL: backupURL,
                replacedExistingCore: true
            )
        } catch {
            // replaceItemAt is atomic, but restore from the just-published backup
            // as a final guard if the destination unexpectedly disappeared.
            if !fileManager.fileExists(atPath: existingCoreURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.copyItem(at: backupURL, to: existingCoreURL)
            }
            throw CoreDownloadError.installFailed(error)
        }
    }

    func existingCoreURL(in coresFolder: URL) throws -> URL? {
        let fileManager = FileManager.default
        var matches: [URL] = []

        if let installedPluginURL,
           installedPluginURL.deletingLastPathComponent().standardizedFileURL == coresFolder.standardizedFileURL,
           fileManager.fileExists(atPath: installedPluginURL.path) {
            let values = try installedPluginURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CoreDownloadError.unsafeInstallDestination
            }
            matches.append(installedPluginURL)
        }

        let coreURLs = try fileManager.contentsOfDirectory(
            at: coresFolder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for url in coreURLs where url.pathExtension.caseInsensitiveCompare(OECorePlugin.pluginExtension) == .orderedSame {
            if matches.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                continue
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            guard let identifier = Bundle(url: url)?.bundleIdentifier else { continue }
            if identifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame {
                matches.append(url)
            }
        }

        guard matches.count <= 1 else {
            throw CoreDownloadError.multipleInstalledCores(bundleIdentifier)
        }
        return matches.first
    }

    func loadInstalledPlugin(at destinationURL: URL) throws -> OECorePlugin {
        if let installedPlugin,
           installedPlugin.url.standardizedFileURL == destinationURL.standardizedFileURL {
            installedPlugin.flushBundleCache()
            return installedPlugin
        }

        if let plugin = OECorePlugin.corePlugin(bundleIdentifier: bundleIdentifier),
           plugin.url.standardizedFileURL == destinationURL.standardizedFileURL {
            plugin.flushBundleCache()
            installedPlugin = plugin
            return plugin
        }

        guard let plugin = try OECorePlugin.plugin(bundleAtURL: destinationURL, forceReload: true) else {
            throw CoreDownloadError.cannotLoadInstalledPlugin
        }
        return plugin
    }

    func rollback(_ transaction: InstallationTransaction, stagingDirectory: URL) {
        let fileManager = FileManager.default
        if transaction.replacedExistingCore, let backupURL = transaction.backupURL,
           fileManager.fileExists(atPath: backupURL.path) {
            let rollbackURL = stagingDirectory.appendingPathComponent("RollbackCore", isDirectory: true)
            do {
                try fileManager.copyItem(at: backupURL, to: rollbackURL)
                _ = try fileManager.replaceItemAt(transaction.destinationURL, withItemAt: rollbackURL)
                installedPlugin?.flushBundleCache()
            } catch {
                DLog("Failed to roll back core \(bundleIdentifier): \(error)")
            }
        } else if !transaction.replacedExistingCore {
            try? fileManager.removeItem(at: transaction.destinationURL)
        }
    }

    func reportSuccess() {
        guard !didReportCompletion else { return }
        didReportCompletion = true
        pendingFinish = false
        isDownloading = false
        progress = 0
        delegate?.coreDownloadDidFinish(self)
    }

    func reportFailure(_ error: Error) {
        guard !didReportCompletion else { return }
        didReportCompletion = true
        pendingFinish = false
        isDownloading = false
        progress = 0

        if let delegate {
            delegate.coreDownloadDidFail(self, withError: error)
        } else {
            NSApplication.shared.presentError(error)
        }
    }

    func finishInstallPipeline(_ pipelineID: UUID) {
        if activeInstallPipeline == pipelineID {
            activeInstallPipeline = nil
        }
    }

    static func isDescendant(_ childURL: URL, of parentURL: URL) -> Bool {
        let childPath = childURL.resolvingSymlinksInPath().standardizedFileURL.path
        let parentPath = parentURL.resolvingSymlinksInPath().standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    static func isMachOOrStaticArchive(_ header: Data) -> Bool {
        let bytes = Array(header.prefix(8))
        let machOMagicValues: [[UInt8]] = [
            [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
            [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
        ]
        if bytes.count >= 4, machOMagicValues.contains(Array(bytes.prefix(4))) {
            return true
        }
        return bytes == Array("!<arch>\n".utf8) || bytes == Array("!<thin>\n".utf8)
    }

    static func relativePath(of url: URL, in pluginURL: URL) -> String {
        let pluginPath = pluginURL.standardizedFileURL.path + "/"
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(pluginPath) else { return url.lastPathComponent }
        return String(filePath.dropFirst(pluginPath.count))
    }
}

// MARK: - Signing

extension CoreDownload {

    /// Ensure the downloaded plugin has at least an ad-hoc signature so macOS 26+
    /// will dlopen it. If the plugin already arrives signed (the standard case for
    /// cores published from our release pipeline, which Developer-ID-signs every
    /// build), the existing signature is preserved unchanged.
    private func adHocSign(_ bundleURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Check for an existing valid signature before potentially overwriting it.
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            check.arguments = ["--verify", bundleURL.path]
            check.standardOutput = FileHandle.nullDevice
            check.standardError = FileHandle.nullDevice
            if (try? check.run()) != nil {
                check.waitUntilExit()
                if check.terminationStatus == 0 {
                    // Already has a valid signature — preserve it.
                    DispatchQueue.main.async { completion(.success(())) }
                    return
                }
            }

            // No valid signature found — apply ad-hoc so the OS will load the bundle.
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", bundleURL.path]

            do {
                try sign.run()
                sign.waitUntilExit()
                if sign.terminationStatus != 0 {
                    let terminationStatus = sign.terminationStatus
                    DLog("codesign exited with status \(terminationStatus) for \(bundleURL.lastPathComponent)")
                    DispatchQueue.main.async {
                        completion(.failure(CoreDownloadError.codeSigningFailed(
                            bundleURL.lastPathComponent,
                            status: terminationStatus
                        )))
                    }
                    return
                }
            } catch {
                DLog("Failed to run codesign for \(bundleURL.lastPathComponent): \(error)")
                DispatchQueue.main.async {
                    completion(.failure(CoreDownloadError.cannotRunCodeSigning(error)))
                }
                return
            }
            DispatchQueue.main.async { completion(.success(())) }
        }
    }
}

private enum CoreDownloadError: LocalizedError {
    case missingDownloadedArchive
    case invalidArchive
    case cannotInspectArchive
    case cannotInspectFile(String, Error)
    case unexpectedPluginCount(Int)
    case pluginOutsideStagingDirectory
    case unsafeSymbolicLink(String)
    case invalidPluginBundle
    case bundleIdentifierMismatch(expected: String, actual: String)
    case bundleVersionMismatch(expected: String, actual: String)
    case missingExecutable
    case executableIsNotMachO
    case cannotReadArchitectures(String, Error)
    case incompatibleBinary(String, expected: String, actual: String)
    case unsafeInstallDestination
    case installDestinationOccupied(String, String)
    case multipleInstalledCores(String)
    case installDidNotProduceBundle
    case installFailed(Error)
    case cannotLoadInstalledPlugin
    case installedVersionMismatch(expected: String, actual: String)
    case cannotRunCodeSigning(Error)
    case codeSigningFailed(String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .missingDownloadedArchive:
            return NSLocalizedString("The core download finished without producing an archive.", comment: "")
        case .invalidArchive:
            return NSLocalizedString("The downloaded core archive could not be extracted.", comment: "")
        case .cannotInspectArchive:
            return NSLocalizedString("The downloaded core archive could not be inspected safely.", comment: "")
        case .cannotInspectFile(let path, let error):
            return String(format: NSLocalizedString("The downloaded core file \"%@\" could not be inspected: %@", comment: ""), path, error.localizedDescription)
        case .unexpectedPluginCount(let count):
            return String(format: NSLocalizedString("The downloaded archive must contain exactly one core plugin, but %ld were found.", comment: ""), count)
        case .pluginOutsideStagingDirectory:
            return NSLocalizedString("The downloaded core plugin points outside its temporary folder.", comment: "")
        case .unsafeSymbolicLink(let path):
            return String(format: NSLocalizedString("The downloaded core contains an unsafe link at \"%@\".", comment: ""), path)
        case .invalidPluginBundle:
            return NSLocalizedString("The downloaded core is not a valid plugin bundle.", comment: "")
        case .bundleIdentifierMismatch(let expected, let actual):
            return String(format: NSLocalizedString("The downloaded core has bundle identifier \"%@\" instead of the expected \"%@\".", comment: ""), actual, expected)
        case .bundleVersionMismatch(let expected, let actual),
             .installedVersionMismatch(let expected, let actual):
            return String(format: NSLocalizedString("The downloaded core has version \"%@\" instead of the expected \"%@\".", comment: ""), actual, expected)
        case .missingExecutable:
            return NSLocalizedString("The downloaded core does not contain its declared executable.", comment: "")
        case .executableIsNotMachO:
            return NSLocalizedString("The downloaded core executable is not a macOS Mach-O binary.", comment: "")
        case .cannotReadArchitectures(let path, let error):
            return String(format: NSLocalizedString("The architectures in \"%@\" could not be checked: %@", comment: ""), path, error.localizedDescription)
        case .incompatibleBinary(let path, let expected, let actual):
            let actualValue = actual.isEmpty ? NSLocalizedString("unknown", comment: "") : actual
            return String(format: NSLocalizedString("The core file \"%@\" does not contain the required %@ code. It contains: %@.", comment: ""), path, expected, actualValue)
        case .unsafeInstallDestination:
            return NSLocalizedString("The core could not be installed because its destination is unsafe.", comment: "")
        case .installDestinationOccupied(let path, let identifier):
            return String(format: NSLocalizedString("The core cannot be installed at \"%@\" because that name is already used by \"%@\".", comment: ""), path, identifier)
        case .multipleInstalledCores(let identifier):
            return String(format: NSLocalizedString("More than one installed core uses bundle identifier \"%@\". Remove the duplicate before updating.", comment: ""), identifier)
        case .installDidNotProduceBundle:
            return NSLocalizedString("The core replacement did not produce an installed bundle.", comment: "")
        case .installFailed(let error):
            return String(format: NSLocalizedString("The core could not be installed safely: %@", comment: ""), error.localizedDescription)
        case .cannotLoadInstalledPlugin:
            return NSLocalizedString("The installed core could not be loaded. The previous core has been restored.", comment: "")
        case .cannotRunCodeSigning(let error):
            return String(format: NSLocalizedString("The downloaded core could not be signed: %@", comment: ""), error.localizedDescription)
        case .codeSigningFailed(let name, let status):
            return String(format: NSLocalizedString("The downloaded core \"%@\" could not be signed (codesign status %d).", comment: ""), name, status)
        }
    }
}

@objc protocol CoreDownloadDelegate: NSObjectProtocol {
    @objc func coreDownloadDidStart(_ download: CoreDownload)
    @objc func coreDownloadDidFinish(_ download: CoreDownload)
    @objc func coreDownloadDidFail(_ download: CoreDownload, withError error: Error?)
}
