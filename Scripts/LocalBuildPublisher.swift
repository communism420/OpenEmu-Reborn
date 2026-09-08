// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-2-Clause
// Maintainer-only local publication. Never linked into the app.
import Darwin
import CryptoKit
import Foundation

struct PublicationFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func publicationRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw PublicationFailure(message) }
}

func publicationRealPath(_ url: URL) throws -> String {
    guard let path = realpath(url.path, nil) else { throw PublicationFailure("Cannot resolve path: \(url.path)") }
    defer { free(path) }
    return String(cString: path)
}

// Include every file and symlink, not just the bundle-directory inode: a build
// can replace the executable while leaving that directory inode unchanged.
func publicationFingerprint(_ folder: URL) throws -> SHA256.Digest {
    var failed = false
    guard let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
        errorHandler: { _, _ in failed = true; return false }) else { throw PublicationFailure("Cannot fingerprint bundle") }
    let urls = entries.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
    try publicationRequire(!failed, "Cannot read complete bundle fingerprint")
    var hash = SHA256()
    for url in urls {
        var info = stat()
        try publicationRequire(lstat(url.path, &info) == 0, "Bundle changed during fingerprinting")
        hash.update(data: Data("\(url.path.dropFirst(folder.path.count))\u{0}\(info.st_mode)\u{0}".utf8))
        switch info.st_mode & S_IFMT {
        case S_IFDIR: break
        case S_IFLNK:
            hash.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8))
        case S_IFREG:
            let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw PublicationFailure("Cannot read bundle file without following links") }
            defer { close(fd) }
            var current = stat()
            try publicationRequire(fstat(fd, &current) == 0 && current.st_dev == info.st_dev && current.st_ino == info.st_ino,
                "Bundle file was replaced during fingerprinting")
            var bytes = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                let amount = read(fd, &bytes, bytes.count)
                if amount == -1 && errno == EINTR { continue }
                try publicationRequire(amount >= 0, "Cannot finish bundle fingerprint")
                if amount == 0 { break }
                hash.update(data: Data(bytes[0..<amount]))
            }
        default: throw PublicationFailure("Special file in app/package; refusing removal")
        }
        hash.update(data: Data([0]))
    }
    return hash.finalize()
}

struct PublicationNode: Equatable {
    let device: dev_t
    let inode: ino_t
    init(_ url: URL, directory: Bool) throws {
        var info = stat()
        try publicationRequire(lstat(url.path, &info) == 0 && info.st_uid == geteuid() &&
            info.st_mode & 0o022 == 0 && info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), "Unsafe or missing owned path: \(url.path)")
        device = info.st_dev
        inode = info.st_ino
    }
}

struct PublicationOwnership: Codable, Equatable {
    let schema: Int
    let kind: String
    let repositoryVolumeUUID: String
    let repositoryInode: UInt64
}

struct PublicationOperations {
    var processGate: () throws -> Void
    var assemble: (_ host: URL, _ cores: URL, _ output: URL, _ signer: String) throws -> Void
    var verify: (_ app: URL, _ signer: String) throws -> Void
    var register: (URL) throws -> Void
    var unregister: (URL) throws -> Void
    var resolve: () throws -> URL
}

final class LocalBuildPublisher {
    static let marker = ".openemu-local-build.json"
    static let allowed = Set(["OpenEmu.app", "README.md", "LICENSE", "BUILD-INFO.txt", marker, ".DS_Store"])
    let repository: URL
    let destination: URL
    let host: URL
    let scratch: URL
    let ownership: PublicationOwnership
    let operations: PublicationOperations

    init(repository: URL, operations: PublicationOperations) throws {
        try publicationRequire(try publicationRealPath(repository) == repository.path, "Repository path must be canonical, without symlinks")
        let identity = try PublicationNode(repository, directory: true)
        // st_dev can change when macOS remounts the same volume after a reboot.
        // Persist its stable UUID; PublicationNode still checks live st_dev.
        let values = try repository.resourceValues(forKeys: [.volumeUUIDStringKey])
        guard let volumeUUIDString = values.volumeUUIDString, let volumeUUID = UUID(uuidString: volumeUUIDString) else {
            throw PublicationFailure("Cannot identify the repository's stable volume UUID")
        }
        try publicationRequire(try PublicationNode(repository, directory: true) == identity,
            "Repository changed while reading its volume identity")
        self.repository = repository
        destination = repository.appendingPathComponent("OpenEmu-Intel-test", isDirectory: true)
        host = repository.appendingPathComponent("tmp/agent/data-folder-derived/Build/Products/Release/OpenEmu.app", isDirectory: true)
        scratch = repository.appendingPathComponent("tmp/agent", isDirectory: true)
        ownership = PublicationOwnership(schema: 2, kind: "org.openemu.local-intel-build",
            repositoryVolumeUUID: volumeUUID.uuidString, repositoryInode: UInt64(identity.inode))
        self.operations = operations
    }

    func requireSafePath(_ url: URL) throws {
        try publicationRequire(try publicationRealPath(url) == url.path, "Symlink or noncanonical path refused: \(url.path)")
        var ancestor = url
        var node = stat()
        try publicationRequire(lstat(url.path, &node) == 0, "Path disappeared during validation")
        if node.st_mode & S_IFMT != S_IFDIR { ancestor.deleteLastPathComponent() }
        while ancestor.path != "/" {
            let marker = ancestor.appendingPathComponent(".openemu-data-folder.plist")
            var info = stat()
            try publicationRequire(lstat(marker.path, &info) != 0 && errno == ENOENT,
                "Selected data folder refused: \(ancestor.path)")
            ancestor.deleteLastPathComponent()
        }
    }

    func validatePackage(_ folder: URL) throws -> PublicationNode {
        try requireSafePath(folder)
        let identity = try PublicationNode(folder, directory: true)
        let children = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        try publicationRequire(Set(children).isSubset(of: Self.allowed) &&
            Set(["OpenEmu.app", "README.md", "LICENSE", "BUILD-INFO.txt", Self.marker]).isSubset(of: Set(children)),
            "Package has missing or unknown files; nothing will be replaced: \(folder.path)")
        for name in children { _ = try PublicationNode(folder.appendingPathComponent(name), directory: name == "OpenEmu.app") }
        let data = try Data(contentsOf: folder.appendingPathComponent(Self.marker))
        let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try publicationRequire(Set(fields?.keys.map { $0 } ?? []) == Set(["schema", "kind", "repositoryVolumeUUID", "repositoryInode"]),
            "Unexpected local package ownership marker; legacy markers require separate verification, not automatic migration")
        let storedOwnership = try JSONDecoder().decode(PublicationOwnership.self, from: data)
        try publicationRequire(storedOwnership.schema == 2, "Unsupported local package ownership schema; no automatic migration")
        try publicationRequire(storedOwnership == ownership,
            "Package does not belong to this repository")
        try validateApp(folder.appendingPathComponent("OpenEmu.app"))
        return identity
    }

    func validateApp(_ app: URL) throws {
        try requireSafePath(app)
        _ = try PublicationNode(app, directory: true)
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        try requireSafePath(infoURL)
        _ = try PublicationNode(infoURL, directory: false)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any]
        try publicationRequire(info?["CFBundleIdentifier"] as? String == "org.openemu.OpenEmu" &&
            info?["CFBundleExecutable"] as? String == "OpenEmu", "Unexpected app identity; refusing consumption")
        // Bundle framework symlinks are allowed, but never followed by the
        // enumerator. A data-folder marker anywhere inside is still refused.
        var enumerationFailed = false
        guard let entries = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [], errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw PublicationFailure("Cannot inspect app bundle") }
        for case let entry as URL in entries {
            try publicationRequire(entry.lastPathComponent != ".openemu-data-folder.plist", "An app contains selected data; refusing removal")
        }
        try publicationRequire(!enumerationFailed, "Cannot completely inspect app bundle")
        let executable = app.appendingPathComponent("Contents/MacOS/OpenEmu")
        try requireSafePath(executable)
        _ = try PublicationNode(executable, directory: false)
    }

    func publish(signer: String, initialCores: URL? = nil, requestedHost: URL? = nil) throws {
        try publicationRequire(signer.range(of: "^[0-9A-Fa-f]{40}$", options: .regularExpression) != nil,
            "An exact 40-hex --signing-identity is required; ad-hoc is not allowed")
        try publicationRequire(requestedHost == nil || requestedHost?.path == host.path,
            "Only the known Release host can be consumed: \(host.path)")
        try requireSafePath(scratch)
        _ = try PublicationNode(scratch, directory: true)
        let lock = scratch.appendingPathComponent(".local-intel-publication.lock")
        let descriptor = open(lock.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw PublicationFailure("Cannot open publication lock") }
        defer { close(descriptor) }
        var lockInfo = stat()
        try publicationRequire(fstat(descriptor, &lockInfo) == 0 && lockInfo.st_uid == geteuid() && lockInfo.st_nlink == 1 &&
            lockInfo.st_mode & S_IFMT == S_IFREG && lockInfo.st_mode & 0o077 == 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0,
            "Another publication is running or the lock is unsafe")
        let lockNode = try PublicationNode(lock, directory: false)
        try publicationRequire(lockNode.device == lockInfo.st_dev && lockNode.inode == lockInfo.st_ino, "Publication lock was replaced")
        try operations.processGate()
        try validateApp(host)
        let hostNode = try PublicationNode(host, directory: true)
        let hostFingerprint = try publicationFingerprint(host)
        var destinationInfo = stat()
        let hasOld = lstat(destination.path, &destinationInfo) == 0
        if !hasOld { try publicationRequire(errno == ENOENT, "Cannot inspect canonical destination") }
        let oldNode = hasOld ? try validatePackage(destination) : nil
        if hasOld { try operations.verify(destination.appendingPathComponent("OpenEmu.app"), signer.uppercased()) }
        let oldFingerprint = hasOld ? try publicationFingerprint(destination) : nil
        if initialCores == nil { try publicationRequire(hasOld, "First publication needs explicit --cores from already-built plugins") }
        let cores = initialCores ?? destination.appendingPathComponent("OpenEmu.app/Contents/PlugIns/Cores", isDirectory: true)
        try requireSafePath(cores)
        _ = try PublicationNode(cores, directory: true)
        let work = scratch.appendingPathComponent(".publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let workNode = try PublicationNode(work, directory: true)
        let output = work.appendingPathComponent("package", isDirectory: true)
        let staged = output.appendingPathComponent("OpenEmu-Intel-test", isDirectory: true)
        var preserveRecovery = false
        defer {
            if !preserveRecovery {
                // Only our newly created staging directory, never a supplied input.
                if (try? PublicationNode(work, directory: true)) == workNode { try? FileManager.default.removeItem(at: work) }
            } else { print("Recovery copies preserved at: \(work.path)") }
        }
        print("Preparing a verified replacement; existing app and cores remain untouched.")
        try operations.assemble(host, cores, output, signer.uppercased())
        try requireSafePath(staged)
        _ = try PublicationNode(staged, directory: true)
        try JSONEncoder().encode(ownership).write(to: staged.appendingPathComponent(Self.marker), options: .atomic)
        let stagedNode = try validatePackage(staged)
        try operations.verify(staged.appendingPathComponent("OpenEmu.app"), signer.uppercased())
        try operations.processGate()
        try publicationRequire(try PublicationNode(host, directory: true) == hostNode, "Input host changed during packaging")
        try publicationRequire(try publicationFingerprint(host) == hostFingerprint, "Input host contents changed during packaging")
        if let oldNode { try publicationRequire(try validatePackage(destination) == oldNode, "Canonical package changed during packaging") }
        // Unregister exact paths only; never alter associations or reset the LS database.
        do {
            try operations.unregister(host)
            try operations.unregister(staged.appendingPathComponent("OpenEmu.app"))
            if hasOld { try operations.unregister(destination.appendingPathComponent("OpenEmu.app")) }
            let flag = UInt32(hasOld ? RENAME_SWAP : RENAME_EXCL)
            try publicationRequire(renamex_np(staged.path, destination.path, flag) == 0, "Atomic package replacement failed; old files remain")
        } catch {
            try? operations.register(host)
            if hasOld { try? operations.register(destination.appendingPathComponent("OpenEmu.app")) }
            throw error
        }
        // The stage now holds the old package. Keep it on any cleanup error.
        preserveRecovery = true
        do {
            try publicationRequire(try validatePackage(destination) == stagedNode, "Published folder identity changed")
            try operations.verify(destination.appendingPathComponent("OpenEmu.app"), signer.uppercased())
            try operations.register(destination.appendingPathComponent("OpenEmu.app"))
            let resolved = try operations.resolve()
            try publicationRequire(try publicationRealPath(resolved) == destination.appendingPathComponent("OpenEmu.app").path,
                "LaunchServices still resolves another OpenEmu: \(resolved.path)")
        } catch {
            try? operations.unregister(destination.appendingPathComponent("OpenEmu.app"))
            var rolledBack = false
            if (try? validatePackage(destination)) == stagedNode &&
                (!hasOld || (try? validatePackage(staged)) == oldNode) {
                rolledBack = (hasOld ? renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) :
                    renamex_np(destination.path, staged.path, UInt32(RENAME_EXCL))) == 0
            }
            if rolledBack {
                if hasOld { try? operations.register(destination.appendingPathComponent("OpenEmu.app")) }
                try? operations.register(host)
            }
            throw PublicationFailure("Publication failed: \(error). \(rolledBack ? "Previous files restored; staged copy retained for inspection." : "Rollback refused or failed; both copies retained for recovery.")")
        }
        // Successful resolution is the commit point. Never consume the input
        // host or previous package until every new-package check has passed.
        try operations.processGate()
        if let oldNode {
            try publicationRequire(try validatePackage(staged) == oldNode, "Old package changed; it has not been deleted")
            try publicationRequire(try publicationFingerprint(staged) == oldFingerprint, "Old package contents changed; recovery copy retained")
        }
        try validateApp(host)
        try publicationRequire(try PublicationNode(host, directory: true) == hostNode, "Input host changed; it has not been consumed")
        try publicationRequire(try publicationFingerprint(host) == hostFingerprint, "Input host contents changed; it has not been consumed")
        if hasOld { try FileManager.default.removeItem(at: staged) }
        try FileManager.default.removeItem(at: host)
        preserveRecovery = false
        print("PASS: \(destination.path)")
        print("Replaced previous local package and consumed only the known Release host app. All core bundles were reused, not rebuilt.")
    }
}

#if !LOCAL_PUBLISHER_TESTS
func publicationCommand(_ executable: String, _ arguments: [String], capture: Bool = false) throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardError = capture ? pipe : FileHandle.standardError
    process.standardOutput = capture ? pipe : FileHandle.standardOutput
    try process.run()
    let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

@main enum LocalPublicationMain {
    static func main() {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            try publicationRequire(!arguments.isEmpty, "Use Scripts/replace-local-intel-build.sh")
            let registry = arguments.removeFirst()
            var signer = ""
            var cores: URL?
            var host: URL?
            while !arguments.isEmpty {
                let option = arguments.removeFirst()
                try publicationRequire(["--signing-identity", "--cores", "--app"].contains(option) && !arguments.isEmpty, "Unknown or incomplete option: \(option)")
                let value = arguments.removeFirst()
                switch option {
                case "--signing-identity": try publicationRequire(signer.isEmpty, "Duplicate signing identity"); signer = value
                case "--cores": try publicationRequire(cores == nil && value.hasPrefix("/"), "--cores needs one absolute path"); cores = URL(fileURLWithPath: value, isDirectory: true)
                default: try publicationRequire(host == nil && value.hasPrefix("/"), "--app needs one absolute path"); host = URL(fileURLWithPath: value, isDirectory: true)
                }
            }
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            func command(_ executable: String, _ arguments: [String]) throws {
                let (status, _) = try publicationCommand(executable, arguments)
                try publicationRequire(status == 0, "Command failed (\(status)): \(executable)")
            }
            let operations = PublicationOperations(processGate: {
                let (status, _) = try publicationCommand("/usr/bin/pgrep", ["-x", "OpenEmu|OpenEmuHelperApp"], capture: true)
                try publicationRequire(status == 1, "Quit OpenEmu and its helper first; process inspection must also succeed")
            }, assemble: { app, cores, output, signer in
                try command("/bin/bash", [repository.appendingPathComponent("Scripts/package-intel-test-build.sh").path,
                    "--app", app.path, "--cores", cores.path, "--output", output.path, "--signing-identity", signer])
            }, verify: { app, signer in
                try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
                try command("/usr/bin/codesign", ["--verify", "--strict", "--test-requirement", "=certificate leaf = H\"\(signer)\"", app.path])
            }, register: { try command(lsregister, ["-f", $0.path]) }, unregister: { app in
                let (status, output) = try publicationCommand(lsregister, ["-u", app.path], capture: true)
                // A never-registered staging copy has no LS entry to remove.
                let notRegistered = status == 1 && output.range(of: "(^|[^0-9])-10814([^0-9]|$)", options: .regularExpression) != nil
                try publicationRequire(status == 0 || notRegistered, "Cannot unregister exact app (\(status)): \(output)")
            }, resolve: {
                let (status, value) = try publicationCommand(registry, ["resolve", "org.openemu.OpenEmu"], capture: true)
                let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
                try publicationRequire(status == 0 && path.hasPrefix("/") && !path.contains("\n"), "Cannot resolve OpenEmu through LaunchServices")
                return URL(fileURLWithPath: path, isDirectory: true)
            })
            try LocalBuildPublisher(repository: repository, operations: operations).publish(signer: signer, initialCores: cores, requestedHost: host)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(1)
        }
    }
}
#endif
