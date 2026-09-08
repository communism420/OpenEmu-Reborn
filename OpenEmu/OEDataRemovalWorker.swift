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
import CryptoKit
import Darwin

private enum OEDataRemovalTransport {
    static let argument = "--openemu-delete-data"
    static let maximumRequestSize = 8 * 1024 * 1024

    struct FileIdentity {
        let device: dev_t
        let inode: ino_t

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
        }

        func matches(_ status: stat) -> Bool {
            device == status.st_dev && inode == status.st_ino
        }
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "org.openemu.DataRemovalWorker", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func systemError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func requestName(token: String) throws -> String {
        guard UUID(uuidString: token) != nil else {
            throw error("The data-removal request has an invalid identifier.")
        }
        return ".openemu-removal-\(token).json"
    }

    static func openDirectory(_ path: String) throws -> Int32 {
        guard (path as NSString).isAbsolutePath else {
            throw error("The data folder must have an absolute path.")
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemError() }
        return descriptor
    }

    static func validateDirectory(_ descriptor: Int32, request: OEDataRemovalRequest) throws {
        try request.validateRoot()
        var held = stat()
        var current = stat()
        guard fstat(descriptor, &held) == 0, lstat(request.rootPath, &current) == 0,
              held.st_mode & S_IFMT == S_IFDIR, current.st_mode & S_IFMT == S_IFDIR,
              FileIdentity(held).matches(current) else {
            throw error("The data folder changed while preparing its removal.")
        }
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw systemError() }
                offset += count
            }
        }
    }

    static func readAll(from descriptor: Int32, maximumSize: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let capacity = buffer.count
        while true {
            let count = Darwin.read(descriptor, &buffer, capacity)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw systemError() }
            if count == 0 { return result }
            guard result.count + count <= maximumSize else {
                throw error("The data-removal request is too large.")
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func removeOwnedRequest(directory: Int32, name: String, identity: FileIdentity) {
        var status = stat()
        guard fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
              status.st_mode & S_IFMT == S_IFREG, identity.matches(status) else { return }
        _ = unlinkat(directory, name, 0)
    }
}

/// Keeps the worker's input pipe open until the app actually exits. A committed
/// request is not executed merely because the user clicked the confirmation.
@MainActor
final class OEDataRemovalJob {
    private let process: Process
    private let input: FileHandle
    private let requestName: String
    private let requestIdentity: OEDataRemovalTransport.FileIdentity
    private let token: String
    private var directory: Int32
    private var committed = false
    private var cancelled = false

    private init(process: Process, input: FileHandle, directory: Int32, requestName: String,
                 requestIdentity: OEDataRemovalTransport.FileIdentity, token: String) {
        self.process = process
        self.input = input
        self.directory = directory
        self.requestName = requestName
        self.requestIdentity = requestIdentity
        self.token = token
    }

    static func launch(request: OEDataRemovalRequest) async throws -> OEDataRemovalJob {
        try request.validateRoot()
        let name = try OEDataRemovalTransport.requestName(token: request.token)
        guard request.requestFileURL.lastPathComponent == name,
              request.requestFileURL.deletingLastPathComponent().standardizedFileURL.path
                == URL(fileURLWithPath: request.rootPath).standardizedFileURL.path,
              let executable = Bundle.main.executableURL else {
            throw OEDataRemovalTransport.error("OpenEmu could not prepare its data-removal worker.")
        }
        let data = try JSONEncoder().encode(request)
        guard data.count <= OEDataRemovalTransport.maximumRequestSize else {
            throw OEDataRemovalTransport.error("The data-removal request is too large.")
        }
        let directory = try OEDataRemovalTransport.openDirectory(request.rootPath)
        var ownsDirectory = true
        defer { if ownsDirectory { close(directory) } }
        try OEDataRemovalTransport.validateDirectory(directory, request: request)
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw OEDataRemovalTransport.systemError() }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            close(descriptor)
            throw OEDataRemovalTransport.systemError()
        }
        let identity = OEDataRemovalTransport.FileIdentity(status)
        do {
            defer { close(descriptor) }
            guard fchmod(descriptor, 0o600) == 0 else { throw OEDataRemovalTransport.systemError() }
            try OEDataRemovalTransport.writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else { throw OEDataRemovalTransport.systemError() }
        } catch {
            OEDataRemovalTransport.removeOwnedRequest(directory: directory, name: name, identity: identity)
            throw error
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = [OEDataRemovalTransport.argument, request.requestFileURL.path,
                             OEDataRemovalTransport.digest(data), request.token, String(getpid())]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        let job = OEDataRemovalJob(process: process, input: inputPipe.fileHandleForWriting,
                                   directory: directory, requestName: name,
                                   requestIdentity: identity, token: request.token)
        ownsDirectory = false
        do {
            let writer = inputPipe.fileHandleForWriting.fileDescriptor
            // A worker inheriting this end would prevent EOF forever. Avoid
            // SIGPIPE as well if the worker exits before the app commits.
            guard fcntl(writer, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(writer, F_SETNOSIGPIPE, 1) == 0 else { throw OEDataRemovalTransport.systemError() }
            let reader = outputPipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(reader, F_GETFL)
            guard flags >= 0, fcntl(reader, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw OEDataRemovalTransport.systemError()
            }
            try process.run()
            try? inputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            defer { try? outputPipe.fileHandleForReading.close() }
            let deadline = Date().addingTimeInterval(10)
            let expected = Data("OPENEMU-REMOVAL-READY \(request.token)\n".utf8)
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 512)
            let capacity = buffer.count
            while Date() < deadline {
                try Task.checkCancellation()
                let count = Darwin.read(reader, &buffer, capacity)
                if count > 0 {
                    received.append(contentsOf: buffer.prefix(count))
                    guard received.count <= 4096 else { break }
                    if received.range(of: expected) != nil, process.isRunning { return job }
                } else if count < 0 && errno != EAGAIN && errno != EINTR {
                    throw OEDataRemovalTransport.systemError()
                }
                if !process.isRunning { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw OEDataRemovalTransport.error("OpenEmu could not start the data-removal worker. Nothing was deleted.")
        } catch {
            job.cancel()
            throw error
        }
    }

    func commitForTermination() {
        guard !committed, !cancelled else { return }
        do {
            try OEDataRemovalTransport.writeAll(Data("COMMIT \(token)\n".utf8), to: input.fileDescriptor)
            committed = true
            // Do not close input here: EOF must come from process exit, after
            // AppKit, the database and other termination observers finish.
        } catch {
            cancel()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = NSLocalizedString("The selected data was not deleted", comment: "Data-removal commit failure")
            alert.informativeText = String(format: NSLocalizedString("OpenEmu could not contact its data-removal worker. Your data is unchanged. OpenEmu will now quit; open it again to retry.\n\n%@", comment: "Data-removal commit failure explanation"), error.localizedDescription)
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "Dismiss data-removal failure"))
            alert.window.isRestorable = false
            alert.window.setFrameAutosaveName("")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    func cancel() {
        guard !committed, !cancelled else { return }
        cancelled = true
        try? input.close()
        if process.isRunning { process.terminate() }
        if directory >= 0 {
            OEDataRemovalTransport.removeOwnedRequest(directory: directory, name: requestName, identity: requestIdentity)
            close(directory)
            directory = -1
        }
    }
}

@MainActor
enum OEDataRemovalWorker {
    private static var committedRequest = false

    /// Called before ordinary app initialization. Worker mode never opens a
    /// library or starts plugin, synchronization or settings controllers.
    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(OEDataRemovalTransport.argument) else { return }
        do {
            try run(arguments: arguments)
            exit(EXIT_SUCCESS)
        } catch {
            // Before commitment the parent is still alive and reports launch
            // failures. Do not leave its readiness wait behind a child alert.
            guard committedRequest else {
                FileHandle.standardError.write(Data("OpenEmu data-removal worker: \(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
            NSApp.setActivationPolicy(.accessory)
            let alert = NSAlert(error: error)
            alert.messageText = NSLocalizedString("OpenEmu could not finish deleting the selected data", comment: "Data-removal worker failure")
            alert.window.isRestorable = false
            alert.window.setFrameAutosaveName("")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            exit(EXIT_FAILURE)
        }
    }

    private static func run(arguments: [String]) throws {
        guard arguments.count == 6, arguments[1] == OEDataRemovalTransport.argument,
              let parent = pid_t(arguments[5]), parent > 1, parent == getppid(),
              arguments[3].count == 64 else {
            throw OEDataRemovalTransport.error("The data-removal worker received an invalid request.")
        }
        let name = try OEDataRemovalTransport.requestName(token: arguments[4])
        let requestURL = URL(fileURLWithPath: arguments[2])
        guard (arguments[2] as NSString).isAbsolutePath, requestURL.lastPathComponent == name else {
            throw OEDataRemovalTransport.error("The data-removal request is in an unexpected location.")
        }
        let directory = try OEDataRemovalTransport.openDirectory(requestURL.deletingLastPathComponent().path)
        defer { close(directory) }
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw OEDataRemovalTransport.systemError() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_mode & 0o777 == 0o600,
              status.st_nlink == 1, status.st_size >= 0,
              status.st_size <= off_t(OEDataRemovalTransport.maximumRequestSize) else {
            close(descriptor)
            throw OEDataRemovalTransport.error("The data-removal request is not a private regular file.")
        }
        let identity = OEDataRemovalTransport.FileIdentity(status)
        let data: Data
        do {
            defer { close(descriptor) }
            data = try OEDataRemovalTransport.readAll(from: descriptor, maximumSize: OEDataRemovalTransport.maximumRequestSize)
        }
        guard OEDataRemovalTransport.digest(data) == arguments[3] else {
            throw OEDataRemovalTransport.error("The data-removal request changed before it could be read.")
        }
        let request = try JSONDecoder().decode(OEDataRemovalRequest.self, from: data)
        guard request.token == arguments[4], request.requestFileURL.standardizedFileURL == requestURL.standardizedFileURL else {
            throw OEDataRemovalTransport.error("The data-removal request does not match this data folder.")
        }
        try OEDataRemovalTransport.validateDirectory(directory, request: request)
        let allowedDomains: Set<String> = ["org.openemu.OpenEmu", "org.openemu.OpenEmu.debug"]
        guard !request.resetNativeDefaults || (!request.defaultsDomains.isEmpty && Set(request.defaultsDomains).isSubset(of: allowedDomains)) else {
            throw OEDataRemovalTransport.error("The request contains an unexpected macOS preferences domain.")
        }
        // Once authenticated, cleanup is confined to this exact request inode,
        // including cancellations or failures before acquiring the writer lock.
        defer { OEDataRemovalTransport.removeOwnedRequest(directory: directory, name: name, identity: identity) }
        try OEDataRemovalTransport.writeAll(Data("OPENEMU-REMOVAL-READY \(request.token)\n".utf8), to: STDOUT_FILENO)
        let command = try OEDataRemovalTransport.readAll(from: STDIN_FILENO, maximumSize: 512)
        guard command == Data("COMMIT \(request.token)\n".utf8) else { return }
        committedRequest = true

        // EOF alone is not evidence that the host is gone (a cancelled launch
        // also closes a pipe). The commit must be followed by actual exit.
        let deadline = Date().addingTimeInterval(5)
        while kill(parent, 0) == 0 || errno == EPERM {
            guard Date() < deadline else {
                throw OEDataRemovalTransport.error("OpenEmu is still running. No data was deleted.")
            }
            usleep(50_000)
        }
        guard errno == ESRCH else { throw OEDataRemovalTransport.systemError() }
        try OEDataRemovalTransport.validateDirectory(directory, request: request)
        let lock = openat(directory, "Settings.plist.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard lock >= 0 else { throw OEDataRemovalTransport.systemError() }
        defer { close(lock) }
        var lockStatus = stat()
        guard fstat(lock, &lockStatus) == 0, lockStatus.st_mode & S_IFMT == S_IFREG,
              lockStatus.st_uid == geteuid() else {
            throw OEDataRemovalTransport.error("OpenEmu's settings lock is not a regular file owned by this user.")
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw OEDataRemovalTransport.error("Another copy of OpenEmu is using this data folder. No data was deleted.")
        }
        defer { _ = flock(lock, LOCK_UN) }
        var currentLock = stat()
        guard fstatat(directory, "Settings.plist.lock", &currentLock, AT_SYMLINK_NOFOLLOW) == 0,
              OEDataRemovalTransport.FileIdentity(lockStatus).matches(currentLock),
              currentLock.st_mode & S_IFMT == S_IFREG else {
            throw OEDataRemovalTransport.error("OpenEmu's settings lock changed. No data was deleted.")
        }
        try OEDataRemovalTransport.validateDirectory(directory, request: request)
        var currentRequest = stat()
        guard fstatat(directory, name, &currentRequest, AT_SYMLINK_NOFOLLOW) == 0,
              identity.matches(currentRequest), currentRequest.st_mode & S_IFMT == S_IFREG,
              unlinkat(directory, name, 0) == 0 else {
            throw OEDataRemovalTransport.error("The data-removal request changed before it could be consumed.")
        }
        _ = try OEDataRemovalEngine.execute(request, applicationURL: Bundle.main.bundleURL) { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            guard let resultingURL else {
                throw OEDataRemovalTransport.error("macOS did not return the location of the items moved to Trash.")
            }
            return resultingURL as URL
        }
        if request.resetNativeDefaults {
            for domain in Set(request.defaultsDomains) {
                UserDefaults.standard.removePersistentDomain(forName: domain)
            }
            guard UserDefaults.standard.synchronize() else {
                throw OEDataRemovalTransport.error("The selected files were processed, but macOS could not save the preferences reset.")
            }
        }
        if request.categories.contains(.preferences) {
            try OEDataRemovalTransport.validateDirectory(directory, request: request)
            var finalLock = stat()
            guard fstatat(directory, "Settings.plist.lock", &finalLock, AT_SYMLINK_NOFOLLOW) == 0,
                  OEDataRemovalTransport.FileIdentity(lockStatus).matches(finalLock),
                  finalLock.st_mode & S_IFMT == S_IFREG, finalLock.st_nlink == 1,
                  unlinkat(directory, "Settings.plist.lock", 0) == 0 else {
                throw OEDataRemovalTransport.error("The selected data was removed, but the settings lock could not be safely removed.")
            }
            // This MUST be the last data/defaults mutation. Keep the old inode
            // locked until return; a fresh launch may now create its own lease.
        }
    }
}
