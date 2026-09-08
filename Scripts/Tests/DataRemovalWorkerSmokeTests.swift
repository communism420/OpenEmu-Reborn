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

// Transport-only collaborators. The production model and deletion engine have
// separate tests; replacing them here guarantees native Trash is never called.
enum OEDataRemovalCategory: String, Codable, Sendable { case preferences, controls }

struct OEDataRemovalRequest: Codable, Sendable {
    let token: String
    let rootPath: String
    let categories: Set<OEDataRemovalCategory>
    let resetNativeDefaults: Bool
    let defaultsDomains: [String]
    let device: dev_t
    let inode: ino_t

    var requestFileURL: URL {
        URL(fileURLWithPath: rootPath).appendingPathComponent(".openemu-removal-\(token).json")
    }

    init(root: URL, categories: Set<OEDataRemovalCategory> = [.preferences]) throws {
        token = UUID().uuidString
        rootPath = root.path
        self.categories = categories
        resetNativeDefaults = false
        defaultsDomains = []
        var status = stat()
        guard lstat(root.path, &status) == 0 else { throw CocoaError(.fileReadUnknown) }
        device = status.st_dev
        inode = status.st_ino
    }

    func validateRoot() throws {
        var status = stat()
        guard rootPath.hasPrefix("/private/tmp/openemu-removal-worker-tests."),
              lstat(rootPath, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              device == status.st_dev, inode == status.st_ino else {
            throw CocoaError(.fileReadInvalidFileName)
        }
    }
}

enum OEDataRemovalEngine {
    static func execute(_ request: OEDataRemovalRequest, applicationURL: URL,
                        trash: (URL) throws -> URL) throws -> URL? {
        // NEVER call trash. Record whether the actual worker acquired the lease.
        let root = URL(fileURLWithPath: request.rootPath)
        let descriptor = open(root.appendingPathComponent("Settings.plist.lock").path, O_RDWR | O_CLOEXEC)
        let held: Bool
        if descriptor >= 0 {
            held = flock(descriptor, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
            close(descriptor)
        } else {
            held = false
        }
        try Data("lock-held=\(held)".utf8).write(to: root.appendingPathComponent("engine-invoked.txt"))
        return nil
    }
}

@main
private struct DataRemovalWorkerSmokeTests {
    @MainActor
    static func main() async throws {
        OEDataRemovalWorker.runIfRequested()
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--committing-test-parent" {
            let request = try JSONDecoder().decode(OEDataRemovalRequest.self,
                                                  from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
            let root = URL(fileURLWithPath: request.rootPath)
            let lock = open(root.appendingPathComponent("Settings.plist.lock").path, O_RDWR | O_CLOEXEC)
            check(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, "test parent holds writer lock")
            let job = try await OEDataRemovalJob.launch(request: request)
            job.commitForTermination()
            try Data("committed".utf8).write(to: root.appendingPathComponent("parent-committed.txt"))
            // Let the supervisor observe that COMMIT alone does not execute.
            try await Task.sleep(nanoseconds: 400_000_000)
            withExtendedLifetime(job) { exit(EXIT_SUCCESS) }
        }

        check(arguments.count == 2, "one private fixture workspace is required")
        let workspace = URL(fileURLWithPath: arguments[1], isDirectory: true)
        check(workspace.path.hasPrefix("/private/tmp/openemu-removal-worker-tests."), "private fixture root required")
        let fm = FileManager.default

        func fixture(_ name: String, categories: Set<OEDataRemovalCategory> = [.preferences]) throws -> (URL, OEDataRemovalRequest) {
            let root = workspace.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            try Data("user-data-sentinel".utf8).write(to: root.appendingPathComponent("game.rom"))
            try Data("{}".utf8).write(to: root.appendingPathComponent("Settings.plist"))
            try Data().write(to: root.appendingPathComponent("Settings.plist.lock"))
            return (root, try OEDataRemovalRequest(root: root, categories: categories))
        }

        let (cancelRoot, cancelRequest) = try fixture("cancel")
        let job = try await OEDataRemovalJob.launch(request: cancelRequest)
        let mode = try fm.attributesOfItem(atPath: cancelRequest.requestFileURL.path)[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o600, "request is private mode 0600")
        job.cancel()
        job.cancel()
        check(!fm.fileExists(atPath: cancelRequest.requestFileURL.path), "cancel removes its own request")
        try checkUnchanged(cancelRoot)

        let (noCommitRoot, noCommitRequest) = try fixture("no-commit")
        let noCommit = try startWorker(noCommitRequest)
        try await waitUntilReady(noCommit, token: noCommitRequest.token)
        try? noCommit.input.close()
        try await waitForExit(noCommit.process)
        check(noCommit.process.terminationStatus == 0, "EOF without commit exits normally")
        check(!fm.fileExists(atPath: noCommitRequest.requestFileURL.path), "authenticated no-commit request is removed")
        try checkUnchanged(noCommitRoot)

        for spoof in ["hash", "token", "parent", "permissions", "symlink", "defaults"] {
            let (root, request) = try fixture("spoof-" + spoof)
            let worker = try startWorker(request, spoof: spoof)
            try? worker.input.close()
            try await waitForExit(worker.process)
            check(worker.process.terminationStatus != 0, "spoofed \(spoof) is rejected")
            check(fm.fileExists(atPath: request.requestFileURL.path), "unauthenticated \(spoof) request is not removed")
            try checkUnchanged(root)
        }

        for category in [OEDataRemovalCategory.preferences, .controls] {
            let (commitRoot, commitRequest) = try fixture("commit-after-exit-" + category.rawValue, categories: [category])
            let launcherData = workspace.appendingPathComponent("launcher-request-" + category.rawValue + ".json")
            try JSONEncoder().encode(commitRequest).write(to: launcherData)
            let launcher = Process()
            launcher.executableURL = Bundle.main.executableURL!
            launcher.arguments = ["--committing-test-parent", launcherData.path]
            launcher.standardOutput = FileHandle.nullDevice
            launcher.standardError = FileHandle.standardError
            try launcher.run()
            try await waitForFile(commitRoot.appendingPathComponent("parent-committed.txt"))
            check(launcher.isRunning, "test parent is still running after COMMIT")
            check(!fm.fileExists(atPath: commitRoot.appendingPathComponent("engine-invoked.txt").path),
                  "COMMIT without parent exit never calls the engine")
            let lockURL = commitRoot.appendingPathComponent("Settings.plist.lock")
            check(fm.fileExists(atPath: lockURL.path), "committed but live parent retains the writer lock")
            try await waitForExit(launcher)
            check(launcher.terminationStatus == 0, "committing parent exits normally")
            let record = commitRoot.appendingPathComponent("engine-invoked.txt")
            try await waitForFile(record)
            check(try String(contentsOf: record, encoding: .utf8) == "lock-held=true", "worker holds exclusive settings lock during engine")
            if category == .preferences {
                try await waitForFileRemoval(lockURL)
            } else {
                try await waitForReleasedLock(lockURL)
                check(fm.fileExists(atPath: lockURL.path), "removing another category keeps the settings lock file")
            }
            check(!fm.fileExists(atPath: commitRequest.requestFileURL.path), "committed request consumed before engine")
            check(try Data(contentsOf: commitRoot.appendingPathComponent("game.rom")) == Data("user-data-sentinel".utf8),
                  "stub engine did not delete data or invoke Trash")
        }
        print("PASS: worker readiness, cancellation retains lock, spoof rejection, parent-exit gate, exclusive lease and final preferences-only lock removal; native Trash never called")
    }

    @MainActor
    private struct Worker {
        let process: Process
        let input: FileHandle
        let output: FileHandle
    }

    @MainActor
    private static func startWorker(_ request: OEDataRemovalRequest, spoof: String? = nil) throws -> Worker {
        let fm = FileManager.default
        var data = try JSONEncoder().encode(request)
        if spoof == "defaults" {
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            object["resetNativeDefaults"] = true
            object["defaultsDomains"] = ["NSGlobalDomain"]
            data = try JSONSerialization.data(withJSONObject: object)
        }
        let file = request.requestFileURL
        if spoof == "symlink" {
            let target = file.deletingLastPathComponent().appendingPathComponent("unrelated-request.json")
            try data.write(to: target)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try fm.createSymbolicLink(at: file, withDestinationURL: target)
        } else {
            try data.write(to: file, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: spoof == "permissions" ? 0o644 : 0o600], ofItemAtPath: file.path)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let input = Pipe()
        let output = Pipe()
        check(fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0, "test pipe is CLOEXEC")
        let process = Process()
        process.executableURL = Bundle.main.executableURL!
        process.arguments = ["--openemu-delete-data", file.path,
                             spoof == "hash" ? String(repeating: "0", count: 64) : digest,
                             spoof == "token" ? UUID().uuidString : request.token,
                             spoof == "parent" ? "1" : String(getpid())]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let reader = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(reader, F_GETFL)
        check(flags >= 0 && fcntl(reader, F_SETFL, flags | O_NONBLOCK) == 0, "test output is nonblocking")
        return Worker(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
    }

    @MainActor
    private static func waitUntilReady(_ worker: Worker, token: String) async throws {
        let deadline = Date().addingTimeInterval(8)
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 512)
        while Date() < deadline {
            let count = Darwin.read(worker.output.fileDescriptor, &bytes, 512)
            if count > 0 { data.append(contentsOf: bytes.prefix(count)) }
            if String(data: data, encoding: .utf8)?.contains("OPENEMU-REMOVAL-READY \(token)\n") == true { return }
            if !worker.process.isRunning { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        worker.process.terminate()
        check(false, "worker did not become ready")
    }

    @MainActor
    private static func waitForExit(_ process: Process) async throws {
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
        if process.isRunning { process.terminate() }
        check(!process.isRunning, "owned test process exited before deadline")
    }

    @MainActor
    private static func waitForFile(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: url.path) && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        check(FileManager.default.fileExists(atPath: url.path), "expected private fixture file appeared")
    }

    @MainActor
    private static func waitForFileRemoval(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(8)
        while FileManager.default.fileExists(atPath: url.path) && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        check(!FileManager.default.fileExists(atPath: url.path), "completed preferences removal leaves no writer lock file")
    }

    @MainActor
    private static func waitForReleasedLock(_ url: URL) async throws {
        let descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        check(descriptor >= 0, "non-preferences cleanup retains its existing lock path")
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                flock(descriptor, LOCK_UN)
                return
            }
            check(errno == EWOULDBLOCK, "retained lock is still held by the finishing worker")
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        check(false, "finished worker releases the retained writer lock")
    }

    private static func checkUnchanged(_ root: URL) throws {
        check(try Data(contentsOf: root.appendingPathComponent("game.rom")) == Data("user-data-sentinel".utf8),
              "user-data sentinel remains byte-identical")
        check(try Data(contentsOf: root.appendingPathComponent("Settings.plist")) == Data("{}".utf8),
              "settings remain byte-identical")
        check(try Data(contentsOf: root.appendingPathComponent("Settings.plist.lock")).isEmpty,
              "cancelled or rejected removal leaves the existing writer lock untouched")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("engine-invoked.txt").path),
              "engine never ran")
    }

    private static func check(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
