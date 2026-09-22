// Private fixtures for the exact production wrapper refresh implementation.
// No real emulator core is built, loaded or installed; no user data is read.
#if REFRESH_BRIDGE_FIXTURE
// A tiny Mach-O used only to exercise the production ad-hoc signing path.
@_cdecl("openemu_refresh_fixture")
public func openemuRefreshFixture() -> Int32 {
    #if REFRESH_BRIDGE_NEW
    return 29
    #else
    return 17
    #endif
}
#else
import Foundation
import Darwin

@main
@MainActor
enum LibretroStubRefreshSmokeTests {
    struct Entry: Equatable {
        let kind: String
        let permissions: Int
        let data: Data?
        let link: String?
    }

    struct Fixture {
        let root: URL
        let stub: URL
        let externalCore: URL
    }

    enum FixtureError: Error { case injectedSignatureFailure, interruptedBeforeActivation }

    static let manager = FileManager.default
    static let executableName = "FixtureBridge"
    static let oldVersion = "fixture-old-17"
    static let newVersion = "fixture-new-29"

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try condition() else { fatalError(message) }
    }

    static func writePlist(_ plist: Any, at url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
    }

    static func metadata(_ stub: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: stub.appendingPathComponent("Contents/Info.plist"))
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            fatalError("Fixture metadata is not a dictionary")
        }
        return result
    }

    static func fixture(_ root: URL, name: String, oldBinary: URL) throws -> Fixture {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        let stub = directory.appendingPathComponent("Fixture-RetroArch.oecoreplugin", isDirectory: true)
        let external = directory.appendingPathComponent("External", isDirectory: true)
        try manager.createDirectory(at: external, withIntermediateDirectories: false)
        let externalCore = external.appendingPathComponent("custom_libretro.dylib")
        try Data("external core sentinel: never load or modify".utf8).write(to: externalCore)
        try manager.createDirectory(at: stub.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try manager.createDirectory(at: stub.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try manager.copyItem(at: oldBinary, to: stub.appendingPathComponent("Contents/MacOS/" + executableName))
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.openemu.tests.WrapperRefresh",
            "CFBundleName": "Private Wrapper Fixture",
            "CFBundleExecutable": executableName,
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "third-party-core-version-1.2.3",
            "CFBundleShortVersionString": "1.2.3",
            "OEGameCoreClass": "OELibretroCoreTranslator",
            "OELibretroCorePath": externalCore.path,
            "OEBridgeVersion": oldVersion,
            "OESystemIdentifiers": ["openemu.system.nes", "openemu.system.snes"],
            "SUFeedURL": "https://example.invalid/untouched-third-party-feed",
            "ThirdPartyMetadata": ["nested": ["keep": true], "ordered": [3, 2, 1], "unicode": "é🌍"],
        ]
        try writePlist(info, at: stub.appendingPathComponent("Contents/Info.plist"))
        try Data([0, 1, 255, 128, 10]).write(to: stub.appendingPathComponent("Contents/Resources/keep.dat"))
        return Fixture(root: directory, stub: stub, externalCore: externalCore)
    }

    /// Snapshot bytes and modes without following links, even for a linked root.
    static func snapshot(_ root: URL) throws -> [String: Entry] {
        var result: [String: Entry] = [:]
        func visit(_ url: URL, relative: String) throws {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let kind = attributes[.type] as? FileAttributeType
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            if kind == .typeSymbolicLink {
                result[relative] = Entry(kind: "link", permissions: permissions, data: nil,
                                         link: try manager.destinationOfSymbolicLink(atPath: url.path))
            } else if kind == .typeDirectory {
                result[relative] = Entry(kind: "directory", permissions: permissions, data: nil, link: nil)
                for child in try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                    try visit(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent)
                }
            } else if kind == .typeRegular {
                result[relative] = Entry(kind: "file", permissions: permissions, data: try Data(contentsOf: url), link: nil)
            } else {
                result[relative] = Entry(kind: kind?.rawValue ?? "unknown", permissions: permissions, data: nil, link: nil)
            }
        }
        try visit(root, relative: "")
        return result
    }

    static func assertNoStage(_ fixture: Fixture) throws {
        let leftovers = try manager.contentsOfDirectory(atPath: fixture.root.path).filter { $0.hasPrefix(".retroarch-refresh-") }
        require(leftovers.isEmpty, "Leaked staging container or legacy top-level wrapper: \(leftovers)")
    }

    /// Match OEPlugin.plugins()'s immediate-child extension filter, including
    /// hidden files. Never load a plugin or read the user's actual Cores folder.
    static func topLevelPluginCandidates(_ directory: URL) throws -> [URL] {
        try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [])
            .filter { $0.pathExtension == "oecoreplugin" }
            .sorted { $0.path < $1.path }
    }

    static func assertSafeStage(_ staged: URL, in fixture: Fixture) throws {
        let container = staged.deletingLastPathComponent()
        require(container.deletingLastPathComponent() == fixture.root,
                "Replacement container was not staged beside the installed wrapper")
        require(container.lastPathComponent.hasPrefix(".retroarch-refresh-") && container.pathExtension.isEmpty,
                "Staging container can be mistaken for an installed plugin")
        require(staged.lastPathComponent == fixture.stub.lastPathComponent, "Nested wrapper filename changed")
        let attributes = try manager.attributesOfItem(atPath: container.path)
        require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                "Staging container is not private to its owner")
        let candidates = try topLevelPluginCandidates(fixture.root)
        require(candidates.map(\.path) == [fixture.stub.path],
                "The loader would discover an extra top-level plugin while refresh is in progress")
    }

    static func failurePreservesWrapper(_ fixture: Fixture, bridge: URL,
                                       signer: (URL) throws -> Void = { _ in
                                           fatalError("Signing must not run after validation/copy fails")
                                       }) throws {
        let before = try snapshot(fixture.stub)
        let externalBefore = try snapshot(fixture.externalCore.deletingLastPathComponent())
        var didThrow = false
        do {
            try OELibretroStubRefresh.refresh(stub: fixture.stub, bridgeExecutable: bridge, version: newVersion, sign: signer)
        } catch {
            didThrow = true
        }
        require(didThrow, "Refresh unexpectedly accepted a failing fixture")
        try require(snapshot(fixture.stub) == before, "Failed refresh changed installed wrapper bytes, type, links or modes")
        try require(snapshot(fixture.externalCore.deletingLastPathComponent()) == externalBefore, "Refresh modified external data")
        try assertNoStage(fixture)
    }

    static func successfulRefresh(_ fixture: Fixture, bridge: URL) throws {
        let original = try metadata(fixture.stub)
        let oldSnapshot = try snapshot(fixture.stub)
        let externalBefore = try snapshot(fixture.externalCore.deletingLastPathComponent())
        var signCalls = 0
        try OELibretroStubRefresh.refresh(stub: fixture.stub, bridgeExecutable: bridge, version: newVersion) { staged in
            signCalls += 1
            require(staged != fixture.stub, "Signer received live installed wrapper")
            try assertSafeStage(staged, in: fixture)
            try require(snapshot(fixture.stub) == oldSnapshot, "Installed wrapper changed before signer succeeded")
            let stagedInfo = try metadata(staged)
            require(stagedInfo["OEBridgeVersion"] as? String == newVersion, "Staged bridge version is stale")
            try require(Data(contentsOf: staged.appendingPathComponent("Contents/MacOS/" + executableName)) == Data(contentsOf: bridge),
                        "Signer did not receive the new executable bytes")
        }
        require(signCalls == 1, "Expected exactly one signature operation")
        var expected = original
        expected["OEBridgeVersion"] = newVersion
        try require(NSDictionary(dictionary: metadata(fixture.stub)).isEqual(to: expected),
                    "Refresh changed metadata other than the bridge stamp, including the external dylib path")
        try require(Data(contentsOf: fixture.stub.appendingPathComponent("Contents/MacOS/" + executableName)) == Data(contentsOf: bridge),
                    "New executable was not installed")
        try require(snapshot(fixture.externalCore.deletingLastPathComponent()) == externalBefore, "External core was changed")
        try require(Data(contentsOf: fixture.stub.appendingPathComponent("Contents/Resources/keep.dat")) == oldSnapshot["Contents/Resources/keep.dat"]?.data,
                    "Third-party resources were not preserved")
        try assertNoStage(fixture)
        print("PASS: successful staged refresh preserves core version, third-party metadata, resources and external dylib path")
    }

    static func interruptedStageIsNotDiscoverable(_ fixture: Fixture, bridge: URL) throws {
        // Preserve a private replica of the on-disk state at the interruption
        // point. Throw from the signer to abort refresh without activating it;
        // no process is killed and no installed wrapper is touched.
        let restartRoot = fixture.root.appendingPathComponent("SimulatedRestartCores", isDirectory: true)
        try manager.createDirectory(at: restartRoot, withIntermediateDirectories: false)
        var preservedStage: URL?
        var visitedSigner = false
        try failurePreservesWrapper(fixture, bridge: bridge) { staged in
            visitedSigner = true
            try assertSafeStage(staged, in: fixture)
            let container = staged.deletingLastPathComponent()
            let retainedContainer = restartRoot.appendingPathComponent(container.lastPathComponent, isDirectory: true)
            try manager.copyItem(at: container, to: retainedContainer)
            try manager.copyItem(at: fixture.stub, to: restartRoot.appendingPathComponent(fixture.stub.lastPathComponent))
            preservedStage = retainedContainer.appendingPathComponent(staged.lastPathComponent)
            throw FixtureError.interruptedBeforeActivation
        }
        require(visitedSigner, "Interruption fixture never reached the pre-activation point")
        guard let preservedStage else { fatalError("Interrupted staging replica was not saved") }
        require(manager.fileExists(atPath: preservedStage.path), "Test accidentally removed the simulated crash residue")
        try require(metadata(preservedStage)["OEBridgeVersion"] as? String == newVersion,
                    "Retained staged replica does not contain the prepared replacement")
        let candidates = try topLevelPluginCandidates(restartRoot)
        require(candidates.map(\.lastPathComponent) == [fixture.stub.lastPathComponent],
                "A restart would discover the interrupted replacement as a duplicate plugin")
        try require(metadata(candidates[0])["OEBridgeVersion"] as? String == oldVersion,
                    "The simulated restart chose the interrupted replacement instead of the old wrapper")
        print("PASS: interrupted staging residue stays invisible to the top-level plugin loader; the old wrapper remains the only candidate")
    }

    static func realSignature(_ fixture: Fixture, bridge: URL) throws {
        let original = try metadata(fixture.stub)
        let externalBefore = try snapshot(fixture.externalCore)
        // No injected signer: exercise exact production codesign + verify.
        try OELibretroStubRefresh.refresh(stub: fixture.stub, bridgeExecutable: bridge, version: newVersion)
        var expected = original
        expected["OEBridgeVersion"] = newVersion
        try require(NSDictionary(dictionary: metadata(fixture.stub)).isEqual(to: expected), "Signing changed preserved metadata")
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", fixture.stub.path]
        try verify.run()
        verify.waitUntilExit()
        require(verify.terminationStatus == 0, "Installed fixture does not have a valid ad-hoc signature")
        try require(snapshot(fixture.externalCore) == externalBefore, "Signing touched external libretro file")
        try assertNoStage(fixture)
        print("PASS: production ad-hoc signing/verification succeeds on a tiny synthetic Mach-O wrapper")
    }

    static func main() throws {
        require(CommandLine.arguments.count == 4, "Expected private fixture directory and two synthetic Mach-O files")
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let oldBinary = URL(fileURLWithPath: CommandLine.arguments[2])
        let newBinary = URL(fileURLWithPath: CommandLine.arguments[3])
        // The runner supplies an already-created, empty directory under mktemp.
        try require(manager.contentsOfDirectory(atPath: root.path).isEmpty, "Fixture directory must be empty")
        require(root.path.hasPrefix("/private/tmp/openemu-libretro-refresh-"), "Refusing a non-private fixture directory")
        try require(Data(contentsOf: oldBinary) != Data(contentsOf: newBinary), "Old/new synthetic executables unexpectedly match")

        try successfulRefresh(fixture(root, name: "success", oldBinary: oldBinary), bridge: newBinary)
        try interruptedStageIsNotDiscoverable(fixture(root, name: "interrupted-stage", oldBinary: oldBinary), bridge: newBinary)

        let missing = try fixture(root, name: "copy-failure", oldBinary: oldBinary)
        try failurePreservesWrapper(missing, bridge: root.appendingPathComponent("missing-bridge"))
        print("PASS: replacement executable copy failure preserves the old wrapper byte-for-byte and cleans staging")

        let failedSign = try fixture(root, name: "sign-failure", oldBinary: oldBinary)
        var failureSignCalls = 0
        try failurePreservesWrapper(failedSign, bridge: newBinary) { staged in
            failureSignCalls += 1
            // Even a signer which changed staged contents before failing must
            // never damage the original wrapper or advance its version stamp.
            try Data("partially signed".utf8).write(to: staged.appendingPathComponent("Contents/Resources/keep.dat"))
            throw FixtureError.injectedSignatureFailure
        }
        require(failureSignCalls == 1, "Injected signature failure was not exercised")
        print("PASS: signature failure preserves all installed bytes and old version; partial staging is removed")

        let badNames: [Any] = ["", ".", "..", "../outside", "Contents/MacOS/escape", "bad\\name", "bad\0name", 42]
        for (index, name) in badNames.enumerated() {
            let item = try fixture(root, name: "bad-name-\(index)", oldBinary: oldBinary)
            var info = try metadata(item.stub)
            info["CFBundleExecutable"] = name
            try writePlist(info, at: item.stub.appendingPathComponent("Contents/Info.plist"))
            try failurePreservesWrapper(item, bridge: newBinary)
        }
        let absentName = try fixture(root, name: "absent-name", oldBinary: oldBinary)
        var noNameInfo = try metadata(absentName.stub)
        noNameInfo.removeValue(forKey: "CFBundleExecutable")
        try writePlist(noNameInfo, at: absentName.stub.appendingPathComponent("Contents/Info.plist"))
        try failurePreservesWrapper(absentName, bridge: newBinary)
        print("PASS: empty, dot, parent, path, backslash, NUL, non-string and absent executable names are rejected")

        for (index, plistData) in [Data("not a plist".utf8), try PropertyListSerialization.data(fromPropertyList: ["not", "a", "dictionary"], format: .xml, options: 0)].enumerated() {
            let item = try fixture(root, name: "bad-plist-\(index)", oldBinary: oldBinary)
            try plistData.write(to: item.stub.appendingPathComponent("Contents/Info.plist"))
            try failurePreservesWrapper(item, bridge: newBinary)
        }
        print("PASS: malformed plist and non-dictionary metadata leave installed bytes unchanged")

        for (index, relative) in ["Contents/Info.plist", "Contents/MacOS/" + executableName,
                                  "Contents/Resources/keep.dat", "Contents/_CodeSignature",
                                  "Contents/MacOS", "Contents/Resources"].enumerated() {
            let item = try fixture(root, name: "linked-entry-\(index)", oldBinary: oldBinary)
            let target = item.stub.appendingPathComponent(relative)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            let destination = relative == "Contents/Info.plist" || relative.hasSuffix(executableName) || relative.hasSuffix("keep.dat")
                ? item.externalCore : item.externalCore.deletingLastPathComponent()
            try manager.createSymbolicLink(at: target, withDestinationURL: destination)
            try failurePreservesWrapper(item, bridge: newBinary)
        }
        let dangling = try fixture(root, name: "dangling-link", oldBinary: oldBinary)
        try manager.createSymbolicLink(atPath: dangling.stub.appendingPathComponent("Contents/Resources/dangling").path,
                                       withDestinationPath: dangling.root.appendingPathComponent("missing-target").path)
        try failurePreservesWrapper(dangling, bridge: newBinary)
        print("PASS: linked plist, executable, resources, signature, directories and dangling links are rejected without following them")

        let linkedRoot = try fixture(root, name: "linked-root", oldBinary: oldBinary)
        let realWrapper = linkedRoot.root.appendingPathComponent("original-target.oecoreplugin")
        try manager.moveItem(at: linkedRoot.stub, to: realWrapper)
        let realBefore = try snapshot(realWrapper)
        try manager.createSymbolicLink(at: linkedRoot.stub, withDestinationURL: realWrapper)
        try failurePreservesWrapper(linkedRoot, bridge: newBinary)
        try require(snapshot(realWrapper) == realBefore, "Linked wrapper target was changed")
        print("PASS: a symlinked wrapper root is rejected and its target remains byte-for-byte unchanged")

        let fifo = try fixture(root, name: "special-file", oldBinary: oldBinary)
        let pipe = fifo.stub.appendingPathComponent("Contents/Resources/not-a-file")
        require(mkfifo(pipe.path, 0o600) == 0, "Could not create a private FIFO fixture")
        try failurePreservesWrapper(fifo, bridge: newBinary)
        print("PASS: non-regular filesystem entries are rejected before copying or signing")

        // Exercise failure while copying the original wrapper, not just while
        // replacing its executable. No administrator rights are requested.
        require(geteuid() != 0, "Run without root privileges so unreadable-copy failure is meaningful")
        let unreadable = try fixture(root, name: "initial-copy-failure", oldBinary: oldBinary)
        let resource = unreadable.stub.appendingPathComponent("Contents/Resources/keep.dat")
        let readableBefore = try snapshot(unreadable.stub)
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: resource.path)
        var initialCopyThrew = false
        do {
            try OELibretroStubRefresh.refresh(stub: unreadable.stub, bridgeExecutable: newBinary, version: newVersion) { _ in
                fatalError("An unreadable original resource unexpectedly reached signing")
            }
        } catch {
            initialCopyThrew = true
        }
        try manager.setAttributes([.posixPermissions: readableBefore["Contents/Resources/keep.dat"]!.permissions], ofItemAtPath: resource.path)
        require(initialCopyThrew, "Original wrapper copy failure was not exercised")
        try require(snapshot(unreadable.stub) == readableBefore, "Initial copy failure modified installed wrapper")
        try assertNoStage(unreadable)
        print("PASS: a partial initial-wrapper copy failure cleans staging and preserves the original wrapper")

        try realSignature(fixture(root, name: "actual-codesign", oldBinary: oldBinary), bridge: newBinary)
        print("PASS: all wrapper refresh fixtures passed; no installed core, user library or Keychain was accessed")
    }
}
#endif
