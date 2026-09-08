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

import Foundation
import Darwin

enum OEDataRemovalCategory: String, CaseIterable, Codable, Sendable {
    case preferences, controls, accounts, library, emulationData, bios
    case screenshots, plugins, shaders, caches, other
}

struct OEDataRemovalRequest: Codable, Sendable {
    let version: Int
    let token: String
    let rootPath: String
    let rootIdentity: UUID
    let rootDevice: UInt64
    let rootInode: UInt64
    let categories: Set<OEDataRemovalCategory>
    let routes: [String: OEDataRemovalCategory]
    let emptyCredentials: Data?
    let resetNativeDefaults: Bool
    let defaultsDomains: [String]

    var rootURL: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }
    var requestFileURL: URL { rootURL.appendingPathComponent(".openemu-removal-\(token).json") }

    static let standardRoutes: [String: OEDataRemovalCategory] = [
        "Settings.plist": .preferences, "Bindings": .controls, ".oe_credentials": .accounts,
        "Game Library": .library, "Save States": .emulationData, "BIOS": .bios,
        "Screenshots": .screenshots, "Cores": .plugins, "Systems": .plugins,
        "Shaders": .shaders, "Caches": .caches, "Temporary": .caches, "Logs": .caches,
        "openvgdb.sqlite": .caches, "openvgdb.sqlite-wal": .caches, "openvgdb.sqlite-shm": .caches
    ]

    init(root: URL, categories: Set<OEDataRemovalCategory>, routes: [String: OEDataRemovalCategory],
         emptyCredentials: Data?, resetNativeDefaults: Bool, defaultsDomains: [String]) throws {
        version = 1
        token = UUID().uuidString
        rootPath = root.standardizedFileURL.path
        rootIdentity = try OEDataFolderIdentity.read(at: root).identifier
        let identity = try OEDataRemovalEngine.identity(at: root)
        rootDevice = identity.device
        rootInode = identity.inode
        self.categories = categories
        self.routes = routes
        self.emptyCredentials = emptyCredentials
        self.resetNativeDefaults = resetNativeDefaults
        self.defaultsDomains = defaultsDomains
        try validateRoot()
    }

    func validateRoot() throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        let protected = ["/", "/Users", "/Applications", "/System", "/Library", "/Volumes",
                         "/private", "/private/tmp", "/tmp", home,
                         home + "/Desktop", home + "/Documents", home + "/Downloads",
                         home + "/Library", home + "/Applications"]
        guard version == 1, UUID(uuidString: token) != nil, !categories.isEmpty,
              (rootPath as NSString).isAbsolutePath, rootURL.standardizedFileURL.path == rootPath,
              rootURL.resolvingSymlinksInPath().path == rootPath, !protected.contains(rootPath),
              try rootURL.resourceValues(forKeys: [.isVolumeKey]).isVolume != true,
              try OEDataFolderIdentity.read(at: rootURL).identifier == rootIdentity else {
            throw OEDataRemovalEngine.failure("The selected OpenEmu data folder could not be verified. Nothing will be removed.")
        }
        let actual = try OEDataRemovalEngine.identity(at: rootURL)
        guard actual.isDirectory, actual.device == rootDevice, actual.inode == rootInode else {
            throw OEDataRemovalEngine.failure("The data folder was moved, disconnected or replaced. Nothing will be removed.")
        }
        for path in routes.keys {
            guard OEDataRemovalEngine.isRelativePath(path), !OEDataRemovalEngine.isTechnical(path) else {
                throw OEDataRemovalEngine.failure("The removal request contains an invalid data path.")
            }
        }
        guard Self.standardRoutes.allSatisfy({ routes[$0.key] == $0.value }) else {
            throw OEDataRemovalEngine.failure("The removal request changes a protected category mapping.")
        }
        guard !categories.contains(.accounts) || emptyCredentials?.isEmpty == false else {
            throw OEDataRemovalEngine.failure("The empty sign-in store is missing from the removal request.")
        }
        guard !resetNativeDefaults || categories.contains(.preferences) else {
            throw OEDataRemovalEngine.failure("The removal request cannot reset unselected preferences.")
        }
    }

    /// Never follow external custom paths. A root-level custom location is not
    /// treated as permission to delete every category in the whole data folder.
    static func relativePath(of url: URL, in root: URL) -> String? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        let prefix = root.standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix), url.resolvingSymlinksInPath().path == path else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return OEDataRemovalEngine.isRelativePath(relative) ? relative : nil
    }
}

enum OEDataRemovalEngine {
    struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: mode_t
        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "org.openemu.DataRemoval", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func identity(at url: URL) throws -> Identity {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Identity(device: UInt64(truncatingIfNeeded: value.st_dev), inode: UInt64(value.st_ino), mode: value.st_mode)
    }

    static func isRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") &&
        !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    static func isTechnical(_ path: String) -> Bool {
        let name = path.split(separator: "/").first.map(String.init) ?? ""
        return name == OEDataFolderIdentity.fileName || name == "Settings.plist.lock" ||
            name.hasPrefix(".openemu-removal-") || name.hasPrefix("OpenEmu Removed Data - ")
    }

    private static func category(for path: String, routes: [String: OEDataRemovalCategory]) -> OEDataRemovalCategory {
        routes.filter { path == $0.key || path.hasPrefix($0.key + "/") }
            .max { $0.key.count < $1.key.count }?.value ?? .other
    }

    /// Resolves categories after normal shutdown, so autosaves and the final
    /// database/queue writes are included. Nested, unselected categories survive.
    static func targets(for request: OEDataRemovalRequest, applicationURL: URL) throws -> [String] {
        try request.validateRoot()
        let fm = FileManager.default
        let app = applicationURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard request.rootPath != app, !request.rootPath.hasPrefix(app + "/") else {
            throw failure("The data folder is inside OpenEmu.app. No application files will be removed.")
        }
        var result: [String] = []
        func visit(_ relative: String) throws {
            if isTechnical(relative) { return }
            let url = request.rootURL.appendingPathComponent(relative)
            let node = try identity(at: url)
            let own = category(for: relative, routes: request.routes)
            let selected = request.categories.contains(own)
            let descendants = request.routes.filter { $0.key.hasPrefix(relative + "/") }.values
            let mixed = descendants.contains { request.categories.contains($0) != selected }
            if selected && !mixed {
                guard url.path != app, !app.hasPrefix(url.path + "/") else {
                    throw failure("OpenEmu.app is inside a selected folder. Move the application outside the data folder before deleting that category.")
                }
                result.append(relative)
            } else if node.isDirectory && (selected || descendants.contains(where: request.categories.contains)) {
                for child in try fm.contentsOfDirectory(atPath: url.path).sorted() {
                    try visit(relative + "/" + child)
                }
            }
            // Symbolic links are leaves. Moving a selected link never follows
            // it or removes files from its external destination.
        }
        for name in try fm.contentsOfDirectory(atPath: request.rootPath).sorted() { try visit(name) }
        return result
    }

    /// The caller owns the existing Settings.plist.lock and has verified parent
    /// exit. Stage by same-volume renames, then move one folder to Trash. There
    /// is deliberately no permanent-delete fallback if Trash is unavailable.
    static func execute(_ request: OEDataRemovalRequest, applicationURL: URL,
                        trash: (URL) throws -> URL) throws -> URL? {
        let selected = try targets(for: request, applicationURL: applicationURL)
        let root = open(request.rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(root) }
        // Keep the recovery group visible when Finder displays the Trash.
        let stageName = "OpenEmu Removed Data - " + request.token
        let stageURL = request.rootURL.appendingPathComponent(stageName, isDirectory: true)
        guard mkdirat(root, stageName, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let stage = openat(root, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(stage) }
        var moved: [(String, Identity)] = []
        var replacements: [(String, Identity)] = []

        do {
            for path in selected {
                try request.validateRoot()
                let original = try identity(at: request.rootURL.appendingPathComponent(path))
                try move(path, from: root, to: stage, expected: original, createParents: true)
                moved.append((path, original))
            }
            // Removed preferences stay absent until the next actual launch.
            // Already marked folders do not re-import legacy macOS settings.
            if request.categories.contains(.accounts), let empty = request.emptyCredentials {
                try writeNew(empty, name: ".oe_credentials", root: root)
                replacements.append((".oe_credentials", try identity(at: request.rootURL.appendingPathComponent(".oe_credentials"))))
            }
            try request.validateRoot()
            // Even an empty staging folder may contain the necessary parent
            // hierarchy for a partial-category removal, so keep it recoverable.
            return try trash(stageURL)
        } catch {
            var restored = true
            do {
                try request.validateRoot()
                for (name, expected) in replacements.reversed() {
                    guard try identity(at: request.rootURL.appendingPathComponent(name)) == expected,
                          unlinkat(root, name, 0) == 0 else { throw failure("A replacement settings file changed during removal.") }
                }
                for (path, expected) in moved.reversed() {
                    try move(path, from: stage, to: root, expected: expected, createParents: false)
                }
            } catch { restored = false }
            if !restored {
                throw failure("Removal stopped. Some data is kept for recovery at \(stageURL.path). Do not delete that folder. Reconnect the disk and restore its contents before trying again.")
            }
            throw failure("Nothing was deleted. The selected data was restored because it could not be moved to Trash. \(error.localizedDescription)")
        }
    }

    private static func parent(of path: String, below root: Int32, create: Bool) throws -> (Int32, String) {
        guard isRelativePath(path) else { throw failure("Invalid relative removal path.") }
        let components = path.split(separator: "/").map(String.init)
        var directory = dup(root)
        guard directory >= 0 else { throw POSIXError(.EMFILE) }
        do {
            for component in components.dropLast() {
                if create && mkdirat(directory, component, 0o700) != 0 && errno != EEXIST {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                close(directory)
                directory = next
            }
            return (directory, components.last!)
        } catch { close(directory); throw error }
    }

    private static func move(_ path: String, from source: Int32, to destination: Int32,
                             expected: Identity, createParents: Bool) throws {
        let (from, name) = try parent(of: path, below: source, create: false)
        defer { close(from) }
        let (to, destinationName) = try parent(of: path, below: destination, create: createParents)
        defer { close(to) }
        var found = stat(), existing = stat()
        guard fstatat(from, name, &found, AT_SYMLINK_NOFOLLOW) == 0,
              UInt64(truncatingIfNeeded: found.st_dev) == expected.device, UInt64(found.st_ino) == expected.inode,
              found.st_mode == expected.mode else { throw failure("A selected file changed before it could be moved.") }
        guard fstatat(to, destinationName, &existing, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else {
            throw failure("A destination already exists. No existing file will be overwritten.")
        }
        // The exclusive rename also protects the gap after the absence check.
        guard renameatx_np(from, name, to, destinationName, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func writeNew(_ data: Data, name: String, root: Int32) throws {
        let descriptor = openat(root, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written == -1 && errno == EINTR { continue }
                    guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            close(descriptor)
        } catch {
            close(descriptor)
            unlinkat(root, name, 0)
            throw error
        }
    }
}
