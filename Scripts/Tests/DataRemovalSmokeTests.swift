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
import OpenEmuBase

private func check(_ condition: Bool, _ message: String) {
    guard condition else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

private func expectFailure(_ message: String, _ operation: () throws -> Void) {
    do {
        try operation()
        check(false, message)
    } catch {}
}

@main
@MainActor
private struct DataRemovalSmokeTests {
    enum FixtureError: Error { case trashUnavailable }
    static let fm = FileManager.default
    static let emptyCredentials = Data("synthetic-empty-encrypted-store".utf8)
    static let samples: [String: OEDataRemovalCategory] = [
        "Settings.plist": .preferences, "Bindings/Default.oebindings": .controls,
        ".oe_credentials": .accounts, "Game Library/roms/Test/Game.rom": .library,
        "Game Library/Library.storedata": .library, "Game Library/Library.storedata-wal": .library,
        "Game Library/Artwork/cover.png": .library, "Game Library/Cheats/game.json": .library,
        "Save States/Game/state.oesavestate/Info.plist": .emulationData,
        "BIOS/firmware.bin": .bios, "Screenshots/game.png": .screenshots,
        "Cores/Test.oecoreplugin/Contents/MacOS/Test": .plugins,
        "Systems/Test.oesystemplugin/Contents/Info.plist": .plugins,
        "Shaders/Custom.slangp": .shaders, "Caches/Shaders/cache.bin": .caches,
        "Temporary/import.bin": .caches, "Logs/core-inventory.txt": .caches,
        "openvgdb.sqlite": .caches, "openvgdb.sqlite-wal": .caches,
        "Manual/Unrecognized Document.txt": .other, "manually-added.rom": .other
    ]

    static func write(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func content(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    static func exists(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    static func fixture(_ name: String, in workspace: URL, populate: Bool = false) throws -> URL {
        let root = workspace.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        _ = try OEDataFolderIdentity.prepare(at: root)
        if populate {
            for path in samples.keys { try write(Data("original:\(path)".utf8), to: root.appendingPathComponent(path)) }
        }
        return root
    }

    static func request(_ root: URL, _ categories: Set<OEDataRemovalCategory>,
                        routes: [String: OEDataRemovalCategory] = OEDataRemovalRequest.standardRoutes,
                        credentials: Data? = emptyCredentials) throws -> OEDataRemovalRequest {
        try OEDataRemovalRequest(root: root, categories: categories, routes: routes,
                                 emptyCredentials: credentials, resetNativeDefaults: false, defaultsDomains: [])
    }

    // The real Trash API is deliberately absent from these tests. All staging
    // folders move only between directories inside the caller's mktemp fixture.
    static func trash(_ stage: URL, in workspace: URL) throws -> URL {
        check(stage.path.hasPrefix(workspace.path + "/"), "test stage stays inside fixture")
        let destination = workspace.appendingPathComponent("fixture-trash-" + UUID().uuidString)
        try fm.moveItem(at: stage, to: destination)
        return destination
    }

    @MainActor
    static func main() throws {
        check(CommandLine.arguments.count == 2, "explicit private fixture directory required")
        check(CommandLine.arguments[1].hasPrefix("/private/tmp/openemu-removal-tests."), "only mktemp fixture accepted")
        // Foundation canonicalizes /private/tmp to /tmp on macOS. Compare all
        // fixture paths using the same canonical form as the production engine.
        let workspace = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let application = workspace.appendingPathComponent("OpenEmu.app", isDirectory: true)
        try fm.createDirectory(at: application, withIntermediateDirectories: false)
        try write(Data("bundled-core-must-survive".utf8), to: application.appendingPathComponent("Contents/PlugIns/Cores/Test"))

        check(OEDataRemovalCategory.allCases.count == 11, "Select All includes all eleven categories")
        for selection in OEDataRemovalCategory.allCases.map({ Set([$0]) }) + [Set(OEDataRemovalCategory.allCases)] {
            let name = selection.count == 1 ? selection.first!.rawValue : "select-all"
            let root = try fixture(name, in: workspace, populate: true)
            let removal = try request(root, selection)
            let technical = ["Settings.plist.lock", removal.requestFileURL.lastPathComponent,
                             ".openemu-removal-staging-previous/recovery.bin"]
            for path in technical { try write(Data("keep:\(path)".utf8), to: root.appendingPathComponent(path)) }
            let marker = try content(root.appendingPathComponent(OEDataFolderIdentity.fileName))
            let moved = try OEDataRemovalEngine.execute(removal, applicationURL: application) { try trash($0, in: workspace) }
            check(moved != nil, "selected category staged to fixture trash: \(name)")
            for (path, category) in samples {
                let original = Data("original:\(path)".utf8)
                if selection.contains(category) {
                    check(try content(moved!.appendingPathComponent(path)) == original, "selected bytes recoverable: \(name)/\(path)")
                    if path == ".oe_credentials" {
                        check(try content(root.appendingPathComponent(path)) == emptyCredentials, "accounts replaced with supplied empty ciphertext")
                        let attrs = try fm.attributesOfItem(atPath: root.appendingPathComponent(path).path)
                        check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "empty credential file permissions are private")
                    } else {
                        check(!exists(root.appendingPathComponent(path)), "selected original removed: \(name)/\(path)")
                    }
                } else {
                    check(try content(root.appendingPathComponent(path)) == original, "unselected bytes retained: \(name)/\(path)")
                    check(!exists(moved!.appendingPathComponent(path)), "unselected file absent from trash")
                }
            }
            check(try content(root.appendingPathComponent(OEDataFolderIdentity.fileName)) == marker, "marker preserved")
            for path in technical { check(try content(root.appendingPathComponent(path)) == Data("keep:\(path)".utf8), "engine preserves technical files; only the finished worker removes the settings lock") }
            print("PASS: independent selection \(name)")
        }

        let nestedRoutes = OEDataRemovalRequest.standardRoutes.merging([
            "Custom": .library, "Custom/States": .emulationData, "Custom/States/Pictures": .screenshots,
            "Custom/Manual": .other
        ]) { _, new in new }
        for selection in [OEDataRemovalCategory.library, .emulationData] {
            let root = try fixture("nested-" + selection.rawValue, in: workspace)
            let nested: [String: OEDataRemovalCategory] = ["Custom/game.rom": .library,
                "Custom/States/game.sav": .emulationData, "Custom/States/Pictures/game.png": .screenshots,
                "Custom/Manual/note.txt": .other]
            for path in nested.keys { try write(Data(path.utf8), to: root.appendingPathComponent(path)) }
            let moved = try OEDataRemovalEngine.execute(request(root, [selection], routes: nestedRoutes), applicationURL: application) { try trash($0, in: workspace) }!
            for (path, category) in nested {
                let location = category == selection ? moved : root
                check(try content(location.appendingPathComponent(path)) == Data(path.utf8), "nested category boundaries: \(path)")
            }
        }
        print("PASS: nested custom routes retain unselected descendants")

        let external = try fixture("external-symlink-target", in: workspace)
        try write(Data("external-sentinel".utf8), to: external.appendingPathComponent("saved/game.sav"))
        let links = try fixture("selected-links", in: workspace)
        try fm.createSymbolicLink(at: links.appendingPathComponent("Game Library"), withDestinationURL: external)
        try fm.createSymbolicLink(at: links.appendingPathComponent("Screenshots"), withDestinationURL: external.appendingPathComponent("missing"))
        let linkTrash = try OEDataRemovalEngine.execute(request(links, [.library, .screenshots]), applicationURL: application) { try trash($0, in: workspace) }!
        check(try fm.destinationOfSymbolicLink(atPath: linkTrash.appendingPathComponent("Game Library").path) == external.path, "selected symlink moved as leaf")
        check(exists(linkTrash.appendingPathComponent("Screenshots")), "dangling symlink moved as leaf")
        check(try content(external.appendingPathComponent("saved/game.sav")) == Data("external-sentinel".utf8), "external symlink destination unchanged")
        let ancestors = try fixture("symlink-ancestor", in: workspace)
        try fm.createSymbolicLink(at: ancestors.appendingPathComponent("Linked"), withDestinationURL: external)
        let ancestorRoutes = OEDataRemovalRequest.standardRoutes.merging(["Linked/saved": .emulationData]) { _, new in new }
        check(try OEDataRemovalEngine.targets(for: request(ancestors, [.emulationData], routes: ancestorRoutes), applicationURL: application).isEmpty,
              "nested route cannot traverse symlink ancestor")
        check(OEDataRemovalRequest.relativePath(of: ancestors.appendingPathComponent("Linked/saved"), in: ancestors) == nil,
              "external custom route through symlink excluded")
        check(OEDataRemovalRequest.relativePath(of: external, in: ancestors) == nil, "external folder excluded")
        check(OEDataRemovalRequest.relativePath(of: ancestors, in: ancestors) == nil, "root itself is not custom deletion route")
        print("PASS: symlink leaves, dangling links and external ancestors")

        for appRelative in ["OpenEmu.app", "Manual/OpenEmu.app"] {
            let root = try fixture("protected-app-" + UUID().uuidString, in: workspace)
            let app = root.appendingPathComponent(appRelative)
            try write(Data("app-sentinel".utf8), to: app.appendingPathComponent("Contents/MacOS/OpenEmu"))
            expectFailure("selected app or ancestor must be rejected") {
                _ = try OEDataRemovalEngine.execute(request(root, [.other]), applicationURL: app) { try trash($0, in: workspace) }
            }
            check(try content(app.appendingPathComponent("Contents/MacOS/OpenEmu")) == Data("app-sentinel".utf8), "app preserved after rejected target")
        }

        let rootIsApp = try fixture("root-is-application", in: workspace)
        try write(Data("application-contents".utf8), to: rootIsApp.appendingPathComponent("Contents/app.bin"))
        expectFailure("the application itself cannot serve as a removal root") {
            _ = try OEDataRemovalEngine.targets(for: request(rootIsApp, [.other]), applicationURL: rootIsApp)
        }
        let rootInApp = try fixture("identified-data-inside-application", in: application)
        try write(Data("nested-application-contents".utf8), to: rootInApp.appendingPathComponent("asset.bin"))
        expectFailure("a root inside the application bundle cannot be removed") {
            _ = try OEDataRemovalEngine.targets(for: request(rootInApp, [.other]), applicationURL: application)
        }

        let replaced = try fixture("replaced-root", in: workspace)
        let replacementRequest = try request(replaced, [.other])
        let old = workspace.appendingPathComponent("original-root-kept")
        let originalMarker = try content(replaced.appendingPathComponent(OEDataFolderIdentity.fileName))
        try fm.moveItem(at: replaced, to: old)
        try fm.createDirectory(at: replaced, withIntermediateDirectories: false)
        try write(originalMarker, to: replaced.appendingPathComponent(OEDataFolderIdentity.fileName))
        expectFailure("same marker cannot authorize substituted root inode") { try replacementRequest.validateRoot() }
        let changedMarker = try fixture("changed-marker", in: workspace)
        let markerRequest = try request(changedMarker, [.other])
        try write(try PropertyListEncoder().encode(OEDataFolderIdentity(version: 1, identifier: UUID())),
                  to: changedMarker.appendingPathComponent(OEDataFolderIdentity.fileName))
        expectFailure("changed marker must reject removal") { try markerRequest.validateRoot() }
        print("PASS: application protection and root/marker substitution rejection")

        let validation = try fixture("request-validation", in: workspace)
        for invalid in ["", "/outside", "../outside", "foo/../outside", "./foo", "foo//bar", "foo/", "bad\0name", "Settings.plist.lock", ".openemu-removal-staging-x/asset", OEDataFolderIdentity.fileName] {
            let invalidRoutes = OEDataRemovalRequest.standardRoutes.merging([invalid: OEDataRemovalCategory.other]) { _, new in new }
            expectFailure("bad route must reject removal: \(invalid)") { _ = try request(validation, [.other], routes: invalidRoutes) }
        }
        let overridden = OEDataRemovalRequest.standardRoutes.merging(["Settings.plist": OEDataRemovalCategory.other]) { _, new in new }
        expectFailure("standard settings category cannot be overridden") { _ = try request(validation, [.other], routes: overridden) }
        for missing in [nil, Data()] as [Data?] {
            expectFailure("missing empty account ciphertext rejected") { _ = try request(validation, [.accounts], credentials: missing) }
        }
        expectFailure("empty category selection rejected") { _ = try request(validation, []) }
        print("PASS: invalid routes and missing credential replacement rejected")

        let rollback = try fixture("trash-failure", in: workspace, populate: true)
        let rollbackLock = rollback.appendingPathComponent("Settings.plist.lock")
        try write(Data("keep-writer-lock".utf8), to: rollbackLock)
        let rollbackRequest = try request(rollback, Set(OEDataRemovalCategory.allCases))
        expectFailure("Trash error must propagate") {
            _ = try OEDataRemovalEngine.execute(rollbackRequest, applicationURL: application) { _ in throw FixtureError.trashUnavailable }
        }
        for path in samples.keys {
            check(try content(rollback.appendingPathComponent(path)) == Data("original:\(path)".utf8), "failed Trash restores original bytes: \(path)")
        }
        check(try content(rollbackLock) == Data("keep-writer-lock".utf8), "failed Trash leaves the writer lock untouched")
        print("PASS: complete rollback restores preferences, accounts and every selected category")

        let conflict = try fixture("rollback-conflict", in: workspace)
        let original = Data("original-settings".utf8)
        try write(original, to: conflict.appendingPathComponent("Settings.plist"))
        let conflictRequest = try request(conflict, [.preferences])
        expectFailure("rollback conflict must be reported") {
            _ = try OEDataRemovalEngine.execute(conflictRequest, applicationURL: application) { _ in
                let live = conflict.appendingPathComponent("Settings.plist")
                check(!exists(live), "preferences are absent before Trash without an empty replacement")
                try write(Data("concurrent-new-settings".utf8), to: live)
                throw FixtureError.trashUnavailable
            }
        }
        check(try content(conflict.appendingPathComponent("Settings.plist")) == Data("concurrent-new-settings".utf8), "rollback never overwrites changed live settings")
        let retained = conflict.appendingPathComponent("OpenEmu Removed Data - " + conflictRequest.token)
        check(try content(retained.appendingPathComponent("Settings.plist")) == original, "conflicting original retained in recovery staging")

        let destinationConflict = try fixture("rollback-destination-conflict", in: workspace)
        try write(Data("original-game".utf8), to: destinationConflict.appendingPathComponent("Game Library/game.rom"))
        let destinationRequest = try request(destinationConflict, [.library])
        expectFailure("new rollback destination must be reported") {
            _ = try OEDataRemovalEngine.execute(destinationRequest, applicationURL: application) { _ in
                try write(Data("new-game".utf8), to: destinationConflict.appendingPathComponent("Game Library/new.rom"))
                throw FixtureError.trashUnavailable
            }
        }
        check(try content(destinationConflict.appendingPathComponent("Game Library/new.rom")) == Data("new-game".utf8), "rollback preserves a concurrently created destination")
        let retainedGame = destinationConflict.appendingPathComponent("OpenEmu Removed Data - " + destinationRequest.token + "/Game Library/game.rom")
        check(try content(retainedGame) == Data("original-game".utf8), "original game preserved for recovery")
        check(try content(application.appendingPathComponent("Contents/PlugIns/Cores/Test")) == Data("bundled-core-must-survive".utf8), "application and bundled cores untouched throughout")
        print("PASS: rollback conflicts never overwrite newer files; recovery originals retained")
        print("PASS: all removal engine tests; only private fixtures used, no app/core builds")
    }
}
