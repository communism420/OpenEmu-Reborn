// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
// 3. Neither the name of the OpenEmu Team nor the names of its contributors may
//    be used to endorse or promote products derived from this software without
//    specific prior written permission.
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

import Darwin
import Foundation

enum OELibretroStubRefresh {
    /// Prepare and authenticate the replacement before touching the installed
    /// wrapper. A failed copy or signature must not stamp a broken stub as new.
    static func refresh(stub: URL, bridgeExecutable: URL, version: String,
                        sign: (URL) throws -> Void = signAndVerify) throws {
        let manager = FileManager.default
        // OEPlugin enumerates hidden entries too. Keep the staging container
        // extensionless so a crash cannot expose a duplicate installed plugin.
        let container = stub.deletingLastPathComponent()
            .appendingPathComponent(".retroarch-refresh-\(UUID().uuidString)")
        let stage = container.appendingPathComponent(stub.lastPathComponent)
        // Generated wrappers contain only regular files/directories. Refuse
        // links before copying/signing, including a linked _CodeSignature.
        let attributes = try manager.attributesOfItem(atPath: stub.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var enumerationError: Error?
        let allowedKeys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let enumerator = manager.enumerator(at: stub, includingPropertiesForKeys: Array(allowedKeys),
                                                   errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        for case let entry as URL in enumerator {
            let values = try entry.resourceValues(forKeys: allowedKeys)
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        if let enumerationError { throw enumerationError }
        // Exclusive creation ensures we only ever clean up our own directory.
        guard mkdir(container.path, S_IRWXU) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { try? manager.removeItem(at: container) }
        try manager.copyItem(at: stub, to: stage)
        let plistURL = stage.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["CFBundleExecutable"] as? String,
              !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let executable = stage.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
        if manager.fileExists(atPath: executable.path) { try manager.removeItem(at: executable) }
        try manager.copyItem(at: bridgeExecutable, to: executable)
        plist["OEBridgeVersion"] = version
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: plistURL, options: .atomic)
        try sign(stage)
        _ = try manager.replaceItemAt(stub, withItemAt: stage, options: .usingNewMetadataOnly)
    }

    private static func signAndVerify(_ stub: URL) throws {
        for arguments in [["--force", "--sign", "-", stub.path],
                          ["--verify", "--deep", "--strict", stub.path]] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            task.arguments = arguments
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
        }
    }
}
