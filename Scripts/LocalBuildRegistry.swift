// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-3-Clause
// Read-only Launch Services inspection. Never registers or launches an app.

import AppKit
import CoreServices
import Foundation

private func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let registryArguments = Array(CommandLine.arguments.dropFirst())
guard registryArguments.count == 2,
      ["resolve", "list"].contains(registryArguments[0]),
      !registryArguments[1].isEmpty else {
    fail("Usage: LocalBuildRegistry <resolve|list> <bundle-identifier>", code: 64)
}

let registryIdentifier = registryArguments[1]
if registryArguments[0] == "resolve" {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: registryIdentifier) else {
        fail("No registered application resolved for \(registryIdentifier). A restricted sandbox can also hide Launch Services results.", code: 2)
    }
    print(url.path)
} else {
    let urls: [URL]
    if #available(macOS 12.0, *) {
        urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: registryIdentifier)
    } else {
        var error: Unmanaged<CFError>?
        if let result = LSCopyApplicationURLsForBundleIdentifier(registryIdentifier as CFString, &error)?.takeRetainedValue(),
           let found = result as? [URL] {
            urls = found
        } else {
            // No results is not proof that the app is absent from disk.
            if let error = error?.takeRetainedValue() {
                fail("Launch Services lookup failed: \(error)", code: 2)
            }
            urls = []
        }
    }
    // The first URL is the system's best match, not our own preference.
    for url in urls { print(url.path) }
}
