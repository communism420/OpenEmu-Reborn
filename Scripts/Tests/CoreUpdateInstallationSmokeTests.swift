// Metadata-only regression fixture for CoreDownload's production installation
// methods. No real core executable, application, user preferences or network.
import Foundation
import OpenEmuKit

final class CoreDownload {
    let bundleIdentifier: String
    weak var installedPlugin: OECorePlugin?
    var installedPluginURL: URL?

    init(identifier: String, plugin: OECorePlugin? = nil) {
        bundleIdentifier = identifier
        installedPlugin = plugin
        installedPluginURL = plugin?.url
    }
}

func DLog(_ message: String) { print(message) }

@main
enum CoreUpdateInstallationSmokeTests {
    static let fm = FileManager.default

    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func writeCore(_ url: URL, identifier: String, version: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": identifier, "CFBundleVersion": version,
                    "CFBundleName": identifier, "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    static func diskVersion(_ url: URL) throws -> String? {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["CFBundleVersion"] as? String
    }

    static func staged(_ root: URL, name: String, identifier: String, version: String = "2.0") throws -> (URL, URL) {
        let stage = root.appendingPathComponent("Staging-" + UUID().uuidString, isDirectory: true)
        let core = stage.appendingPathComponent(name + ".oecoreplugin", isDirectory: true)
        try writeCore(core, identifier: identifier, version: version)
        return (stage, core)
    }

    static func main() throws {
        require(CommandLine.arguments.count == 3, "Expected private fixture root and mode")
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let cores = root.appendingPathComponent("Cores", isDirectory: true)
        let bundled = root.appendingPathComponent("Bundled/FirstUpdate.oecoreplugin", isDirectory: true)
        let identifier = "org.openemu.tests.FirstUpdate"

        if CommandLine.arguments[2] == "restart" {
            // The real loader visits data-folder plugins before bundled ones.
            let new = try OECorePlugin.plugin(bundleAtURL: cores.appendingPathComponent("FirstUpdate.oecoreplugin"))!
            let bundledLookup = try OECorePlugin.plugin(bundleAtURL: bundled)!
            require(new.version == "2.0", "Next launch failed to load the installed update")
            require(new === bundledLookup, "Bundled version overrode the installed update")
            require(try diskVersion(bundled) == "1.0", "Bundled core was modified")
            print("PASS: next process loads updated data-folder core; original bundled core remains unchanged")
            return
        }

        try fm.createDirectory(at: cores, withIntermediateDirectories: true)
        try writeCore(bundled, identifier: identifier, version: "1.0")
        let old = try OECorePlugin.plugin(bundleAtURL: bundled)!
        // A metadata cache already exists, so registration cannot scan any
        // default folder or the main bundle. All subsequent lookup is private.
        OECorePlugin.registerClass()
        let first = CoreDownload(identifier: identifier, plugin: old)
        let (stage, archiveCore) = try staged(root, name: "FirstUpdate", identifier: identifier)
        let transaction = try first.install(archiveCore, from: stage, into: cores)
        let result = try first.loadInstalledPlugin(at: transaction.destinationURL)
        require(!transaction.replacedExistingCore, "First update overwrote the bundled core")
        require(result.requiresRestart && result.version == "2.0", "Installed metadata is stale")
        require(result.plugin === old && old.version == "1.0", "Live plugin was replaced or mutated")
        require(try diskVersion(transaction.destinationURL) == "2.0", "First update was rolled back")
        require(try diskVersion(bundled) == "1.0", "App bundle was modified")
        print("PASS: same-name bundled update persists; live cached plugin remains untouched")

        let existingID = "org.openemu.tests.ExistingUpdate"
        let existingURL = cores.appendingPathComponent("ExistingUpdate.oecoreplugin", isDirectory: true)
        try writeCore(existingURL, identifier: existingID, version: "1.0")
        let existingPlugin = try OECorePlugin.plugin(bundleAtURL: existingURL)!
        let existing = CoreDownload(identifier: existingID, plugin: existingPlugin)
        let (existingStage, existingArchive) = try staged(root, name: "ExistingUpdate", identifier: existingID)
        let replacement = try existing.install(existingArchive, from: existingStage, into: cores)
        let existingResult = try existing.loadInstalledPlugin(at: replacement.destinationURL)
        require(replacement.replacedExistingCore, "Existing core not replaced")
        require(existingResult.requiresRestart && existingResult.version == "2.0", "Existing update metadata is stale")
        require(existingResult.plugin === existingPlugin && existingPlugin.version == "1.0", "Existing live cache was changed")
        require(try diskVersion(replacement.backupURL!) == "1.0", "Old version not backed up")
        existing.rollback(replacement, stagingDirectory: existingStage)
        require(try diskVersion(existingURL) == "1.0", "Failed update did not restore old core")
        print("PASS: data-folder update preserves a backup and rollback restores it")

        let newID = "org.openemu.tests.BrandNew"
        let brandNew = CoreDownload(identifier: newID)
        let (newStage, newArchive) = try staged(root, name: "BrandNew", identifier: newID)
        let newTransaction = try brandNew.install(newArchive, from: newStage, into: cores)
        let newResult = try brandNew.loadInstalledPlugin(at: newTransaction.destinationURL)
        require(!newResult.requiresRestart && newResult.plugin.version == "2.0", "Brand-new core unnecessarily requires restart")
        print("PASS: brand-new core metadata registers normally without restart")

        let badID = "org.openemu.tests.InvalidUpdate"
        let bad = CoreDownload(identifier: badID)
        let (badStage, badArchive) = try staged(root, name: "InvalidUpdate", identifier: badID)
        let badTransaction = try bad.install(badArchive, from: badStage, into: cores)
        try writeCore(badTransaction.destinationURL, identifier: "org.openemu.tests.Wrong", version: "2.0")
        do {
            _ = try bad.loadInstalledPlugin(at: badTransaction.destinationURL)
            preconditionFailure("Wrong installed bundle identifier was accepted")
        } catch {
            bad.rollback(badTransaction, stagingDirectory: badStage)
        }
        require(!fm.fileExists(atPath: badTransaction.destinationURL.path), "Invalid new installation was not removed")
        print("PASS: real installation failure still removes the invalid new bundle")

        let duplicateID = "org.openemu.tests.Duplicate"
        let duplicateA = cores.appendingPathComponent("DuplicateA.oecoreplugin")
        let duplicateB = cores.appendingPathComponent("DuplicateB.oecoreplugin")
        try writeCore(duplicateA, identifier: duplicateID, version: "1.0")
        try writeCore(duplicateB, identifier: duplicateID, version: "1.0")
        let duplicate = CoreDownload(identifier: duplicateID)
        let (duplicateStage, duplicateArchive) = try staged(root, name: "DuplicateA", identifier: duplicateID)
        do {
            _ = try duplicate.install(duplicateArchive, from: duplicateStage, into: cores)
            preconditionFailure("Ambiguous duplicate installation was accepted")
        } catch CoreDownloadError.multipleInstalledCores { }
        require(try diskVersion(duplicateA) == "1.0", "Duplicate A was changed")
        require(try diskVersion(duplicateB) == "1.0", "Duplicate B was changed")
        print("PASS: ambiguous destination remains rejected without changing either core")
    }
}
