// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-3-Clause
import Foundation
internal import OpenEmuKitPrivate

@main struct HelperLocalizationSwiftProbe {
    static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["CFFIXED_USER_HOME"],
              home.hasPrefix("/private/tmp/openemu-helper-localization."),
              let source = environment["OE_LOCALIZATION_SOURCE"] else {
            fatalError("Only the isolated helper fixture may run")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: source).appendingPathComponent("ru.lproj/Localizable.strings"))
        let table = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
        let key = "The emulator could not load ROM."
        let translated = NSLocalizedString("The emulator could not load ROM.", bundle: OEHostLocalizationBundle(), comment: "Helper fixture")
        precondition(translated == table[key])
        let arguments: [String] = OEHelperLanguageArguments()
        precondition(arguments.first == "-AppleLanguages" && arguments.count == 2)
        print("PASS: Swift imports and uses the same header-only helper bundle and language-argument functions")
    }
}
