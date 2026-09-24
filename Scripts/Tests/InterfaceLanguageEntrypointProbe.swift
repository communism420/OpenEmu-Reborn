// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-2-Clause
import AppKit

// Module-local replacement for the imported C entry point. Compile this only
// with the production OpenEmuLaunch.swift and language bootstrap. It reads
// localization at exactly the place AppKit would first start, but opens no UI.
func NSApplicationMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let environment = ProcessInfo.processInfo.environment
    let expected = environment["OPENEMU_LANGUAGE_EXPECTED"]!
    precondition(NSLocalizedString("Cancel", comment: "probe") == expected,
                 "Profile language must be active before NSApplicationMain")
    let language = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["AppleLanguages"] as? [String]
    let identifier = Bundle.main.bundleIdentifier!
    precondition(identifier.hasPrefix("org.openemu.InterfaceLanguageFixture."))
    precondition(UserDefaults.standard.persistentDomain(forName: identifier)?["AppleLanguages"] == nil,
                 "Profile language must never become a persistent AppleLanguages setting")
    print("PASS: before NSApplicationMain; Cancel=\(expected); volatile languages=\(language ?? [])")
    return 0
}
