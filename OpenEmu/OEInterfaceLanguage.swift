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

/// A read-only preview of one profile setting, before AppKit localizes its nibs.
/// OEPreferences remains the only writer. This must never configure storage,
/// create a marker/lock, migrate preferences, mount a disk or show a picker.
enum OEInterfaceLanguage {
    static let preferenceKey = "OEInterfaceLanguage"
    static let systemDefault = ""
    private static let locatorDomain = "org.openemu.OpenEmu"
    private static let markerName = ".openemu-data-folder.plist"

    static func availableLanguages(in localizations: [String]) -> [String] {
        Array(Set(localizations.filter { $0 != "Base" && !$0.isEmpty }))
            .sorted { nativeName(for: $0) < nativeName(for: $1) }
    }

    static func nativeName(for identifier: String) -> String {
        Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Explicit launch/test language overrides always win. AppleLanguages is
    /// changed only in the volatile argument domain of this process, never in
    /// the app's persistent preferences or macOS's global language preferences.
    static func bootstrap(defaults: UserDefaults = .standard,
                          arguments: [String] = ProcessInfo.processInfo.arguments,
                          environment: [String: String] = ProcessInfo.processInfo.environment,
                          localizations: [String] = Bundle.main.localizations) {
        var argumentDomain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        guard argumentDomain["AppleLanguages"] == nil,
              !arguments.contains("-AppleLanguages"), !arguments.contains("--AppleLanguages"),
              environment["XCTestConfigurationFilePath"] == nil,
              !arguments.contains("--openemu-delete-data") else { return }
        let language = argumentDomain[preferenceKey] as? String ?? selectedLanguage(arguments: arguments, environment: environment,
                  localizations: localizations, readLocator: {
                      defaults.persistentDomain(forName: locatorDomain) ?? [:]
                  })
        guard let language, language != systemDefault, language != "Base",
              localizations.contains(language) else { return }
        argumentDomain["AppleLanguages"] = [language]
        defaults.setVolatileDomain(argumentDomain, forName: UserDefaults.argumentDomain)
    }

    /// Missing/corrupt settings use the system language without changing data.
    /// The normal data-folder bootstrap remains responsible for recovery/errors.
    static func selectedLanguage(arguments: [String], environment: [String: String],
                                 localizations: [String], readLocator: () -> [String: Any],
                                 resolveBookmark: (Data) throws -> URL = resolveBookmark) -> String? {
        guard environment["XCTestConfigurationFilePath"] == nil,
              !arguments.contains("--openemu-delete-data") else { return nil }
        let root: URL
        let expectedID: UUID?
        if let index = arguments.firstIndex(of: "--data-folder") {
            // An invalid explicit selection must never read the real profile.
            guard index + 1 < arguments.count,
                  (arguments[index + 1] as NSString).isAbsolutePath else { return nil }
            root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            expectedID = nil
        } else {
            let locator = readLocator()
            guard let bookmark = locator["OEDataFolderBookmark"] as? Data,
                  let identifier = locator["OEDataFolderIdentifier"] as? String,
                  let identity = UUID(uuidString: identifier),
                  let resolved = try? resolveBookmark(bookmark) else { return nil }
            // Never use the saved path as a fallback for an unavailable bookmark.
            root = resolved
            expectedID = identity
        }
        guard let language = try? readLanguage(at: root, expectedID: expectedID),
              language != systemDefault, localizations.contains(language), language != "Base" else { return nil }
        return language
    }

    private static func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                       relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    // This is the existing data-folder marker schema, decoded without calling
    // prepareForUse (which may create a marker). Normal startup validates it too.
    private struct Identity: Decodable {
        let version: Int
        let identifier: UUID
    }

    private static func readLanguage(at input: URL, expectedID: UUID?) throws -> String? {
        guard input.isFileURL, input.host == nil || input.host == "localhost" else { return nil }
        let root = input.standardizedFileURL.resolvingSymlinksInPath()
        guard root.path != "/" else { return nil }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        let marker = try readFile(markerName, in: directory, limit: 64 * 1024)
        let identity = try PropertyListDecoder().decode(Identity.self, from: marker)
        guard identity.version == 1, expectedID == nil || identity.identifier == expectedID else { return nil }
        let settings = try readFile("Settings.plist", in: directory, limit: 16 * 1024 * 1024)
        // A reset or replacement while reading cannot make a different profile
        // supply its language. Missing files after reset simply mean defaults.
        guard try readFile(markerName, in: directory, limit: 64 * 1024) == marker else { return nil }
        var opened = stat(), current = stat()
        guard fstat(directory, &opened) == 0, lstat(root.path, &current) == 0,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else { return nil }
        let values = try PropertyListSerialization.propertyList(from: settings, options: [], format: nil)
        return (values as? [String: Any])?[preferenceKey] as? String
    }

    private static func readFile(_ name: String, in directory: Int32, limit: Int) throws -> Data {
        let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= Int64(limit) else { throw CocoaError(.fileReadCorruptFile) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, result.count + count <= limit else { throw CocoaError(.fileReadCorruptFile) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}
