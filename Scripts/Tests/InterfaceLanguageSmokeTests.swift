// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import OpenEmuBase

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) rethrows {
    if try !value() { fatalError(message) }
}

/// Never forwards a persistent-domain operation to the user's preferences.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    var arguments: [String: Any] = [:]
    var locator: [String: Any] = [:]
    var locatorReads = 0
    var volatileWrites = 0
    override func volatileDomain(forName domainName: String) -> [String: Any] {
        precondition(domainName == UserDefaults.argumentDomain)
        return arguments
    }
    override func setVolatileDomain(_ domain: [String: Any], forName domainName: String) {
        precondition(domainName == UserDefaults.argumentDomain)
        arguments = domain
        volatileWrites += 1
    }
    override func persistentDomain(forName domainName: String) -> [String: Any]? {
        precondition(domainName == "org.openemu.OpenEmu")
        locatorReads += 1
        return locator
    }
    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        fatalError("Language bootstrap must not write persistent defaults")
    }
    override func set(_ value: Any?, forKey defaultName: String) {
        fatalError("Language bootstrap must not persist AppleLanguages")
    }
}

@main
private struct InterfaceLanguageSmokeTests {
    static func main() throws {
        precondition(CommandLine.arguments.count == 2)
        let workspace = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default
        let languages = ["en", "ru", "fr", "fr-CA", "Base"]
        let key = OEInterfaceLanguage.preferenceKey
        func write(_ object: Any, _ url: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: url)
        }
        func profile(_ name: String, language: Any) throws -> (URL, UUID) {
            let root = workspace.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            let id = UUID()
            try write(["version": 1, "identifier": id.uuidString], root.appendingPathComponent(".openemu-data-folder.plist"))
            try write([key: language, "unrelated": "kept"], root.appendingPathComponent("Settings.plist"))
            return (root, id)
        }
        let (russian, russianID) = try profile("Русская папка", language: "ru")
        let (french, frenchID) = try profile("French", language: "fr")
        let marker = russian.appendingPathComponent(".openemu-data-folder.plist")
        let settings = russian.appendingPathComponent("Settings.plist")
        let markerBefore = try Data(contentsOf: marker)
        let settingsBefore = try Data(contentsOf: settings)
        func explicit(_ root: URL, environment: [String: String] = [:]) -> String? {
            OEInterfaceLanguage.selectedLanguage(arguments: ["fixture", "--data-folder", root.path],
                environment: environment, localizations: languages,
                readLocator: { fatalError("Explicit/test profile must not inspect real locator") })
        }
        check(explicit(russian) == "ru" && explicit(french) == "fr", "Languages are per profile")
        check(explicit(russian, environment: ["XCTestConfigurationFilePath": "fixture"]) == nil, "XCTest does not inherit profile")
        for arguments in [["fixture", "--data-folder"], ["fixture", "--data-folder", "relative"],
                          ["fixture", "--openemu-delete-data", "fixture"]] {
            check(OEInterfaceLanguage.selectedLanguage(arguments: arguments, environment: [:], localizations: languages,
                readLocator: { fatalError("Invalid explicit path/worker must not inspect real locator") }) == nil,
                "Invalid explicit selection/worker does not fall back")
        }
        let rootBefore = try fm.contentsOfDirectory(atPath: russian.path)
        let defaults = MemoryDefaults()
        defaults.arguments = ["unrelatedArgument": "kept"]
        OEInterfaceLanguage.bootstrap(defaults: defaults, arguments: ["fixture", "--data-folder", russian.path],
                                      environment: [:], localizations: languages)
        check(defaults.arguments["AppleLanguages"] as? [String] == ["ru"] && defaults.arguments["unrelatedArgument"] as? String == "kept",
              "Only process-local AppleLanguages is added")
        check(defaults.locatorReads == 0 && defaults.volatileWrites == 1, "Explicit profile needs no real locator")
        for override in [["AppleLanguages": ["fr"]], [key: "fr"]] as [[String: Any]] {
            let overridden = MemoryDefaults()
            overridden.arguments = override
            OEInterfaceLanguage.bootstrap(defaults: overridden, arguments: ["fixture", "--data-folder", russian.path],
                                          environment: [:], localizations: languages)
            check(overridden.arguments["AppleLanguages"] as? [String] == ["fr"], "Launch argument language wins")
            check(overridden.locatorReads == 0, "Override does not inspect real locator")
        }
        for arguments in [["fixture", "-AppleLanguages", "(fr)"], ["fixture", "--AppleLanguages", "(fr)"]] {
            let overridden = MemoryDefaults()
            OEInterfaceLanguage.bootstrap(defaults: overridden, arguments: arguments, environment: [:], localizations: languages)
            check(overridden.locatorReads == 0 && overridden.volatileWrites == 0, "Explicit native argument is left unchanged")
        }
        try check(Data(contentsOf: marker) == markerBefore && Data(contentsOf: settings) == settingsBefore,
                  "Bootstrap never rewrites marker/settings")
        try check(fm.contentsOfDirectory(atPath: russian.path) == rootBefore, "Bootstrap creates no lock or storage directories")

        // Real bookmark resolution follows a moved identified folder; its stale
        // saved path is deliberately irrelevant. Only fixture bookmarks are used.
        let bookmark = try french.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        var locator: [String: Any] = ["OEDataFolderBookmark": bookmark, "OEDataFolderIdentifier": frenchID.uuidString,
                                     "OEDataFolderPath": "/never/use/the/old/path"]
        func ordinary() -> String? {
            OEInterfaceLanguage.selectedLanguage(arguments: ["fixture"], environment: [:], localizations: languages, readLocator: { locator })
        }
        check(ordinary() == "fr", "Ordinary startup reads exact bookmark identity")
        let moved = workspace.appendingPathComponent("Moved French", isDirectory: true)
        try fm.moveItem(at: french, to: moved)
        check(ordinary() == "fr", "Bookmark follows renamed profile without writing locator")
        locator["OEDataFolderIdentifier"] = russianID.uuidString
        check(ordinary() == nil, "Mismatched marker is not read")
        locator["OEDataFolderIdentifier"] = frenchID.uuidString
        locator["OEDataFolderBookmark"] = Data("invalid bookmark".utf8)
        check(ordinary() == nil, "Corrupt bookmark cannot fall back to path")
        locator.removeValue(forKey: "OEDataFolderBookmark")
        check(ordinary() == nil, "Incomplete locator has no fallback")

        for value: Any in ["", "unknown-language", "Base", 123, ["ru"]] {
            try write([key: value], settings)
            check(explicit(russian) == nil, "System default/unsupported/malformed languages are ignored")
        }
        try fm.removeItem(at: settings)
        check(explicit(russian) == nil, "Removed settings restore system default")
        try fm.createSymbolicLink(at: settings, withDestinationURL: moved.appendingPathComponent("Settings.plist"))
        check(explicit(russian) == nil, "Linked Settings.plist is not read")
        try fm.removeItem(at: settings)
        try settingsBefore.write(to: settings)
        try fm.removeItem(at: marker)
        check(explicit(russian) == nil, "Unmarked profile is not adopted by language bootstrap")
        try fm.createSymbolicLink(at: marker, withDestinationURL: moved.appendingPathComponent(".openemu-data-folder.plist"))
        check(explicit(russian) == nil, "Linked marker is not read")
        try fm.removeItem(at: marker)
        try write(["version": 2, "identifier": russianID.uuidString], marker)
        check(explicit(russian) == nil, "Future marker schema is not accepted")
        try markerBefore.write(to: marker)
        check(explicit(russian) == "ru", "Valid profile recovers after rejected reads")
        check(OEInterfaceLanguage.availableLanguages(in: languages + ["ru"]).count == 4, "All real localizations, no Base/duplicates")
        check(OEInterfaceLanguage.nativeName(for: "ru").lowercased().contains("рус"), "Native language labels")

        // Exercise the actual settings writer: new language must not replace
        // unrelated settings; a failed write must leave both views unchanged.
        try OEPreferences.configure(url: settings, readOnly: false)
        try OEPreferences.shared.setValues([key: "fr"])
        check(explicit(russian) == "fr", "Saved language is available before the next app launch")
        let saved = try Data(contentsOf: settings)
        try check((PropertyListSerialization.propertyList(from: saved, format: nil) as? [String: Any])?["unrelated"] as? String == "kept",
              "Language write retains existing settings")
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: russian.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: russian.path) }
        do {
            try OEPreferences.shared.setValues([key: "ru"])
            fatalError("Unwritable language selection must fail")
        } catch {}
        check(OEPreferences.shared.string(forKey: key) == "fr", "Failed selection retains saved language")
        try check(Data(contentsOf: settings) == saved, "Failed selection retains file")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: russian.path)
        try OEPreferences.shared.resetForTermination()
        check(explicit(russian) == nil, "Actual settings reset restores system language on next launch")
        print("PASS: per-profile languages, bookmark identity/move, read-only bootstrap, argument/test overrides, persistence failures and reset")
    }
}
