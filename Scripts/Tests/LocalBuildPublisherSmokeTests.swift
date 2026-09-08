// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-2-Clause
// Private filesystem fixtures only. All signing, process and LaunchServices
// operations are injected; no app, Keychain, real registration or Trash calls.
import Foundation

private let fixtureSigner = String(repeating: "A", count: 40)
private func expect(_ value: Bool, _ message: String) throws {
    if !value { throw PublicationFailure("TEST FAILED: \(message)") }
}

private final class Fixture {
    let root: URL
    let cores: URL
    var publisher: LocalBuildPublisher!
    var failAssembly = false
    var failFinalVerification = false
    var wrongResolution = false
    var running = false
    var failUnregister = false
    var failFinalGate = false
    var stagedForAttempt = false
    var afterResolve: (() throws -> Void)?
    var checks = 0
    var assembledCores: URL?
    var events = [String]()
    var beforeAssemblyReturns: (() throws -> Void)?
    init(_ temporary: URL, _ name: String) throws {
        root = temporary.appendingPathComponent(name, isDirectory: true)
        cores = root.appendingPathComponent("CoreCache", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tmp/agent"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cores.appendingPathComponent("Nestopia.oecoreplugin/Contents"), withIntermediateDirectories: true)
        try Data("unchanged core".utf8).write(to: cores.appendingPathComponent("Nestopia.oecoreplugin/Contents/core"))
        let operations = PublicationOperations(processGate: { [unowned self] in
            events.append("gate")
            if running { throw PublicationFailure("fixture running app") }
            if failFinalGate && events.suffix(2).first == "resolve" { throw PublicationFailure("fixture postcommit process gate") }
        }, assemble: { [unowned self] host, inputCores, output, _ in
            events.append("assemble")
            stagedForAttempt = true
            assembledCores = inputCores
            if failAssembly { throw PublicationFailure("fixture cancelled signing") }
            let package = output.appendingPathComponent("OpenEmu-Intel-test", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let app = package.appendingPathComponent("OpenEmu.app", isDirectory: true)
            try FileManager.default.copyItem(at: host, to: app)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/PlugIns"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: inputCores, to: app.appendingPathComponent("Contents/PlugIns/Cores"))
            for name in ["README.md", "LICENSE", "BUILD-INFO.txt"] { try Data(name.utf8).write(to: package.appendingPathComponent(name)) }
            try beforeAssemblyReturns?()
        }, verify: { [unowned self] app, _ in
            events.append("verify")
            checks += 1
            if failFinalVerification && stagedForAttempt && app.path == publisher.destination.appendingPathComponent("OpenEmu.app").path {
                throw PublicationFailure("fixture final verification failed")
            }
        }, register: { [unowned self] app in events.append("register:\(app.path)") }, unregister: { [unowned self] app in
            events.append("unregister:\(app.path)")
            if failUnregister && app != publisher.host { throw PublicationFailure("fixture unregister failure") }
        }, resolve: { [unowned self] in
            events.append("resolve")
            try afterResolve?()
            return wrongResolution ? root.appendingPathComponent("Other.app") : publisher.destination.appendingPathComponent("OpenEmu.app")
        })
        publisher = try LocalBuildPublisher(repository: root, operations: operations)
        try makeHost("original host")
    }
    func makeHost(_ text: String) throws {
        try FileManager.default.createDirectory(at: publisher.host.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: publisher.host.appendingPathComponent("Contents/MacOS/OpenEmu"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.openemu.OpenEmu", "CFBundleExecutable": "OpenEmu"],
            format: .xml, options: 0).write(to: publisher.host.appendingPathComponent("Contents/Info.plist"))
    }
    func installFirst() throws { try publisher.publish(signer: fixtureSigner, initialCores: cores); stagedForAttempt = false }
    func fails(_ action: () throws -> Void) throws {
        do { try action() } catch { print("PASS expected refusal: \(error)"); return }
        throw PublicationFailure("TEST FAILED: expected publication refusal")
    }
    func snapshot(_ folder: URL) throws -> [String: Data] {
        if !FileManager.default.fileExists(atPath: folder.path) { return [:] }
        var result = [String: Data]()
        let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])!
        for case let url as URL in entries {
            let key = String(url.path.dropFirst(folder.path.count))
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { result[key] = Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8) }
            else if values.isRegularFile == true { result[key] = try Data(contentsOf: url) }
        }
        return result
    }
}

@main private enum PublisherSmokeTests {
    static func main() {
        do { try run() } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run() throws {
        let workspace = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try expect(workspace.path.hasPrefix("/private/tmp/openemu-local-publisher-tests."), "private fixture root required")
        let initial = try Fixture(workspace, "initial")
        let coresBefore = try initial.snapshot(initial.cores)
        try initial.installFirst()
        try expect(!FileManager.default.fileExists(atPath: initial.publisher.host.path), "input host consumed only after success")
        try expect(try initial.snapshot(initial.cores) == coresBefore, "seed cores retained byte-for-byte")
        _ = try initial.publisher.validatePackage(initial.publisher.destination)
        let initialMarker = try JSONSerialization.jsonObject(with: Data(contentsOf:
            initial.publisher.destination.appendingPathComponent(LocalBuildPublisher.marker))) as! [String: Any]
        let volumeUUID = try initial.root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        try expect(initialMarker["schema"] as? Int == 2 && initialMarker["repositoryDevice"] == nil,
            "persistent ownership uses schema 2 without a reboot-dependent device number")
        try expect(initialMarker["repositoryVolumeUUID"] as? String == volumeUUID.flatMap { UUID(uuidString: $0)?.uuidString },
            "persistent ownership matches the repository's stable volume UUID")
        try expect((initialMarker["repositoryInode"] as? NSNumber)?.uint64Value == UInt64(PublicationNode(initial.root, directory: true).inode),
            "persistent ownership retains the repository inode")
        initial.publisher = try LocalBuildPublisher(repository: initial.root, operations: initial.publisher.operations)
        _ = try initial.publisher.validatePackage(initial.publisher.destination)
        try expect(initial.events.first == "gate" && initial.events.contains("resolve"), "process and registry checks run")
        let oldCoreBytes = try initial.snapshot(initial.publisher.destination.appendingPathComponent("OpenEmu.app/Contents/PlugIns/Cores"))
        try initial.makeHost("next host")
        try initial.publisher.publish(signer: fixtureSigner)
        try expect(initial.assembledCores?.path == initial.publisher.destination.appendingPathComponent("OpenEmu.app/Contents/PlugIns/Cores").path, "default reuses canonical cores")
        try expect(try initial.snapshot(initial.publisher.destination.appendingPathComponent("OpenEmu.app/Contents/PlugIns/Cores")) == oldCoreBytes, "default cores preserved")
        let scratchEntries = try FileManager.default.contentsOfDirectory(atPath: initial.publisher.scratch.path)
        try expect(!scratchEntries.contains(where: { $0.hasPrefix(".publish-") }), "successful staging removed")
        print("PASS initial and replacement publication; canonical cores reused; only input app consumed")

        for scenario in ["assembly", "finalVerify", "resolve", "running", "unregister"] {
            let fixture = try Fixture(workspace, scenario)
            try fixture.installFirst()
            try fixture.makeHost("unpublished replacement")
            let old = try fixture.snapshot(fixture.publisher.destination)
            let input = try fixture.snapshot(fixture.publisher.host)
            fixture.failAssembly = scenario == "assembly"
            fixture.failFinalVerification = scenario == "finalVerify"
            fixture.wrongResolution = scenario == "resolve"
            fixture.running = scenario == "running"
            fixture.failUnregister = scenario == "unregister"
            try fixture.fails { try fixture.publisher.publish(signer: fixtureSigner) }
            try expect(try fixture.snapshot(fixture.publisher.destination) == old, "\(scenario) preserves previous package")
            try expect(try fixture.snapshot(fixture.publisher.host) == input, "\(scenario) preserves input host")
        }
        for scenario in ["unknown", "missingMarker", "wrongMarker", "extraMarkerField", "wrongVolume", "wrongInode", "wrongSchema", "legacyMarker", "dataMarker", "symlink"] {
            let fixture = try Fixture(workspace, scenario)
            try fixture.installFirst()
            try fixture.makeHost("unpublished replacement")
            let destination = fixture.publisher.destination
            let marker = destination.appendingPathComponent(LocalBuildPublisher.marker)
            switch scenario {
            case "unknown": try Data("personal notes".utf8).write(to: destination.appendingPathComponent("Notes.txt"))
            case "missingMarker": try FileManager.default.removeItem(at: marker)
            case "wrongMarker": try Data("{}".utf8).write(to: marker)
            case "extraMarkerField":
                var object = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as! [String: Any]
                object["unexpected"] = true
                try JSONSerialization.data(withJSONObject: object).write(to: marker)
            case "wrongVolume", "wrongInode", "wrongSchema", "legacyMarker":
                var object = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as! [String: Any]
                switch scenario {
                case "wrongVolume":
                    var otherUUID = UUID().uuidString
                    while otherUUID == object["repositoryVolumeUUID"] as? String { otherUUID = UUID().uuidString }
                    object["repositoryVolumeUUID"] = otherUUID
                case "wrongInode": object["repositoryInode"] = (object["repositoryInode"] as! NSNumber).uint64Value + 1
                case "wrongSchema": object["schema"] = 3
                default:
                    object["schema"] = 1
                    object.removeValue(forKey: "repositoryVolumeUUID")
                    object["repositoryDevice"] = Int64(try PublicationNode(fixture.root, directory: true).device)
                }
                try JSONSerialization.data(withJSONObject: object).write(to: marker)
            case "dataMarker": try Data("data folder".utf8).write(to: destination.appendingPathComponent(".openemu-data-folder.plist"))
            default:
                let elsewhere = fixture.root.appendingPathComponent("UntouchedPackage")
                try FileManager.default.moveItem(at: destination, to: elsewhere)
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: elsewhere)
            }
            let before = try fixture.snapshot(destination)
            let hostBefore = try fixture.snapshot(fixture.publisher.host)
            fixture.events.removeAll()
            try fixture.fails { try fixture.publisher.publish(signer: fixtureSigner) }
            try expect(try fixture.snapshot(destination) == before, "\(scenario) leaves target untouched")
            try expect(try fixture.snapshot(fixture.publisher.host) == hostBefore, "\(scenario) leaves input host untouched")
            try expect(!fixture.events.contains("assemble"), "\(scenario) fails before assembling or signing a replacement")
        }
        print("PASS stable volume UUID and inode ownership; wrong volume, unknown schema and legacy marker refused without migration")
        let badInput = try Fixture(workspace, "bad-input")
        try badInput.fails { try badInput.publisher.publish(signer: fixtureSigner, initialCores: badInput.cores, requestedHost: badInput.root.appendingPathComponent("Other.app")) }
        try badInput.fails { try badInput.publisher.publish(signer: "-", initialCores: badInput.cores) }
        try expect(badInput.events.isEmpty, "invalid inputs fail before external operations")
        let concurrent = try Fixture(workspace, "concurrent-change")
        try concurrent.installFirst()
        try concurrent.makeHost("next")
        concurrent.beforeAssemblyReturns = {
            try Data("do not delete".utf8).write(to: concurrent.publisher.destination.appendingPathComponent("Notes.txt"))
        }
        try concurrent.fails { try concurrent.publisher.publish(signer: fixtureSigner) }
        try expect(FileManager.default.fileExists(atPath: concurrent.publisher.destination.appendingPathComponent("Notes.txt").path), "concurrent unknown file preserved")
        for scenario in ["postcommitGate", "postcommitOldMutation", "rollbackReplacement", "hostInPlaceChange"] {
            let fixture = try Fixture(workspace, scenario)
            try fixture.installFirst()
            try fixture.makeHost("next")
            let old = try fixture.snapshot(fixture.publisher.destination)
            fixture.failFinalGate = scenario == "postcommitGate"
            fixture.afterResolve = {
                if scenario == "postcommitOldMutation" {
                    let folders = try FileManager.default.contentsOfDirectory(at: fixture.publisher.scratch, includingPropertiesForKeys: nil)
                    let stage = folders.first { $0.lastPathComponent.hasPrefix(".publish-") }!
                    try Data("must survive".utf8).write(to: stage.appendingPathComponent("package/OpenEmu-Intel-test/Notes.txt"))
                } else if scenario == "rollbackReplacement" {
                    try Data("must survive".utf8).write(to: fixture.publisher.destination.appendingPathComponent("Notes.txt"))
                    throw PublicationFailure("fixture substituted destination")
                } else if scenario == "hostInPlaceChange" {
                    try fixture.makeHost("new build appeared inside same host directory")
                }
            }
            try fixture.fails { try fixture.publisher.publish(signer: fixtureSigner) }
            try expect(FileManager.default.fileExists(atPath: fixture.publisher.host.path), "postcommit failure retains host")
            let stages = try FileManager.default.contentsOfDirectory(at: fixture.publisher.scratch, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".publish-") }
            try expect(stages.count == 1, "postcommit failure retains recovery stage")
            let retained = stages[0].appendingPathComponent("package/OpenEmu-Intel-test")
            if scenario == "postcommitOldMutation" {
                try expect(FileManager.default.fileExists(atPath: retained.appendingPathComponent("Notes.txt").path), "unvalidated old addition not deleted")
            } else {
                try expect(try fixture.snapshot(retained) == old, "old package remains byte-for-byte recoverable")
            }
            if scenario == "rollbackReplacement" {
                try expect(FileManager.default.fileExists(atPath: fixture.publisher.destination.appendingPathComponent("Notes.txt").path), "rollback does not overwrite substituted destination")
            }
        }
        print("PASS ownership, allowlist, data-folder/symlink guards, cancellation, rollback, fixed host and signer validation")
    }
}
