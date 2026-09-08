// Copyright (c) 2022, OpenEmu Team
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
import OpenEmuBase
import Sentry

// Configure before telemetry, bindings, shaders or core controllers can cache
// paths. Never fall back to the legacy Library folder in a helper process.
let dataRootPrefix = "--org.openemu.data-root="
let dataRootArguments = ProcessInfo.processInfo.arguments.filter { $0.hasPrefix(dataRootPrefix) }
do {
    guard dataRootArguments.count == 1 else { throw CocoaError(.fileReadInvalidFileName) }
    let path = String(dataRootArguments[0].dropFirst(dataRootPrefix.count))
    guard (path as NSString).isAbsolutePath else { throw CocoaError(.fileReadInvalidFileName) }
    try OEStoragePaths.configure(dataRootURL: URL(fileURLWithPath: path, isDirectory: true))
    try OEPreferences.configure(url: OEStoragePaths.dataRootURL.appendingPathComponent("Settings.plist"), readOnly: true)
} catch {
    FileHandle.standardError.write(Data("OpenEmu helper data folder: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}

// The host is the sole settings writer; this process reads the same file.
let consentValue = OEPreferences.shared.bool(forKey: "OEIntelSentryCrashReportingEnabled")
let sentryDSN = (Bundle.main.object(forInfoDictionaryKey: "OESentryDSN") as? String)?
    .trimmingCharacters(in: .whitespacesAndNewlines)
let sentryReleasePrefix = (Bundle.main.object(forInfoDictionaryKey: "OESentryReleasePrefix") as? String)?
    .trimmingCharacters(in: .whitespacesAndNewlines)
let effectiveSentryReleasePrefix = sentryReleasePrefix.flatMap { $0.isEmpty ? nil : $0 }
    ?? "openemu-intel"

if consentValue, let sentryDSN, !sentryDSN.isEmpty {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    SentrySDK.start { options in
        options.cacheDirectoryPath = OEStoragePaths.cachesURL.appendingPathComponent("Sentry/Helper", isDirectory: true).path
        options.dsn              = sentryDSN
        options.releaseName      = "\(effectiveSentryReleasePrefix)@\(version)+\(build)"
        options.environment      = "production"
        options.debug            = false
        options.tracesSampleRate = 0.2
        options.enableLogs       = true
        options.enableMetricKit  = true
        options.appHangTimeoutInterval = 1.0
    }

    // Read the game context saved by the host before launching this process.
    func ctx(_ key: String) -> String? {
        OEPreferences.shared.string(forKey: key)
    }
    let game   = ctx("OESentryActiveGame")
    let system = ctx("OESentryActiveSystem")
    let core   = ctx("OESentryActiveCore")
    if game != nil || system != nil || core != nil {
        SentrySDK.configureScope { scope in
            scope.setContext(value: [
                "game":   game   ?? "Unknown",
                "system": system ?? "Unknown",
                "core":   core   ?? "Unknown",
                "process": "helper",
            ], key: "emulation")
        }
    } else {
        SentrySDK.configureScope { scope in
            scope.setContext(value: ["process": "helper"], key: "emulation")
        }
    }
}

if let wait = ProcessInfo.processInfo.environment["OE_HELPER_WAIT_FOR_DEBUGGER"] as? NSString, wait.boolValue {
    XPCDebugSupport.waitForDebugger(until: .distantFuture)
}

OpenEmuXPCHelperApp.run()
