// Test-generated private keys are never persisted, printed or put in Keychain.
import CryptoKit
import Foundation

@main
enum CoreUpdateSecuritySmokeTests {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func rejects(_ label: String, expected: OECoreUpdateSecurity.ValidationError? = nil,
                        _ operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure("Accepted invalid input: \(label)")
        } catch {
            if let expected {
                require(String(describing: error) == String(describing: expected), "Wrong rejection for \(label): \(error)")
            }
        }
    }

    static func feed(_ items: String) -> Data {
        Data("""
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>\(items)</channel></rss>
        """.utf8)
    }

    static func item(version: String = "2.0", minimum: String = "11.0", signature: String?, length: String,
                     hardware: String? = "x86_64 arm64", location: String = "https://downloads.example.test/core.zip") -> String {
        let signatureAttribute = signature.map { " sparkle:edSignature=\"\($0)\"" } ?? ""
        let processorElement = hardware.map { "<sparkle:hardwareRequirements>\($0)</sparkle:hardwareRequirements>" } ?? ""
        return """
        <item><sparkle:minimumSystemVersion>\(minimum)</sparkle:minimumSystemVersion>\(processorElement)<enclosure url="\(location)" sparkle:version="\(version)"\(signatureAttribute) length="\(length)"/></item>
        """
    }

    static func main() throws {
        require(CommandLine.arguments.count == 2, "Expected a private fixture directory")
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let archiveURL = root.appendingPathComponent("not-an-executable.archive")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: archiveURL)
        let signer = Curve25519.Signing.PrivateKey()
        let publicKey = signer.publicKey.rawRepresentation.base64EncodedString()
        let signature = try signer.signature(for: bytes).base64EncodedString()
        let validXML = feed(item(signature: signature, length: String(bytes.count)))
        let valid = try CoreAppcastItem.parse(validXML, publicKey: publicKey).first!
        try valid.verifyArchive(at: archiveURL)
        print("PASS: valid Ed25519 signature authenticates the original archive bytes")

        var changed = bytes
        changed[20] ^= 1
        try changed.write(to: archiveURL)
        var reachedExtraction = false
        rejects("altered archive", expected: .invalidSignature) {
            try valid.verifyArchive(at: archiveURL)
            reachedExtraction = true
        }
        require(!reachedExtraction, "Altered bytes reached extraction")
        try Data(bytes.dropLast()).write(to: archiveURL)
        rejects("truncated archive", expected: .unexpectedLength) { try valid.verifyArchive(at: archiveURL) }
        try (bytes + Data([0])).write(to: archiveURL)
        rejects("oversized archive", expected: .unexpectedLength) { try valid.verifyArchive(at: archiveURL) }
        try bytes.write(to: archiveURL)

        let wrongKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let wrongSignerItem = try CoreAppcastItem.parse(validXML, publicKey: wrongKey).first!
        rejects("wrong signing key", expected: .invalidSignature) { try wrongSignerItem.verifyArchive(at: archiveURL) }
        let forged = try CoreAppcastItem.parse(feed(item(signature: Data(repeating: 0, count: 64).base64EncodedString(), length: String(bytes.count))), publicKey: publicKey).first!
        rejects("forged signature", expected: .invalidSignature) { try forged.verifyArchive(at: archiveURL) }
        print("PASS: changed/truncated/oversized archives and wrong/forged signatures are rejected before extraction")

        let malformedItems = [
            item(signature: nil, length: "4096"),
            item(signature: "not-base64", length: "4096"),
            item(signature: Data(repeating: 0, count: 63).base64EncodedString(), length: "4096"),
            item(signature: signature, length: "0"),
            item(signature: signature, length: "-1"),
            item(signature: signature, length: "9999999999999999999999999999999"),
            item(signature: signature, length: String(OECoreUpdateSecurity.maximumArchiveLength + 1)),
            item(signature: signature, length: "4096", hardware: nil),
            item(signature: signature, length: "4096", hardware: ""),
            item(signature: signature, length: "4096", hardware: "i386"),
            item(signature: signature, length: "4096", hardware: "x86_64 unknown"),
            item(signature: signature, length: "4096", location: "http://downloads.example.test/core.zip"),
            item(signature: signature, length: "4096", location: "file:///tmp/core.zip"),
            item(signature: signature, length: "4096", location: "https://user:password@downloads.example.test/core.zip"),
            item(signature: signature, length: "4096", location: "https://downloads.example.test/core.zip#fragment"),
            item(version: "", signature: signature, length: "4096"),
            item(minimum: "", signature: signature, length: "4096"),
        ]
        for (index, xml) in malformedItems.enumerated() {
            rejects("malformed metadata \(index)", expected: .invalidMetadata) {
                _ = try CoreAppcastItem.parse(feed(xml), publicKey: publicKey)
            }
        }
        rejects("invalid public key", expected: .untrustedFeed) { _ = try CoreAppcastItem.parse(validXML, publicKey: "bad-key") }
        rejects("malformed XML") { _ = try CoreAppcastItem.parse(Data("<rss><channel><item>".utf8), publicKey: publicKey) }
        print("PASS: missing or malformed signature/length/CPU/URL/version metadata is rejected")

        let unsorted = feed(["2.0", "1.9", "10.0", "2.1"].map {
            item(version: $0, signature: signature, length: "4096")
        }.joined())
        let sorted = try CoreAppcastItem.parse(unsorted, publicKey: publicKey)
        require(sorted.map(\.version) == ["10.0", "2.1", "2.0", "1.9"], "Feed order determined the update version")
        let mixed = try CoreAppcastItem.parse(feed(
            item(version: "4.0", minimum: "99.0", signature: signature, length: "4096") +
            item(version: "3.0", signature: signature, length: "4096", hardware: "arm64") +
            item(version: "2.0", signature: signature, length: "4096", hardware: "x86_64")
        ), publicKey: publicKey)
        require(mixed.first { $0.supports(architecture: "x86_64", osVersion: "26.0") }?.version == "2.0", "Intel selected an ARM-only or too-new-OS update")
        require(mixed.first { $0.supports(architecture: "arm64", osVersion: "26.0") }?.version == "3.0", "ARM selected an incompatible update")
        require(!valid.supports(architecture: "x86_64", osVersion: "10.15"), "Minimum OS requirement ignored")
        require(valid.supports(architecture: "arm64", osVersion: "11.0"), "Universal archive not accepted on ARM")
        require(!valid.supports(architecture: "i386", osVersion: "26.0"), "Unsupported CPU accepted")
        print("PASS: highest compatible version is selected independently of XML order and CPU")

        let directory = "https://raw.githubusercontent.com/communism420/OpenEmu-Reborn/main/Updates/x86_64/"
        let armDirectory = "https://raw.githubusercontent.com/communism420/OpenEmu-Reborn/main/Updates/arm64/"
        let metadata: [String: Any] = [
            "SUPublicEDKey": publicKey,
            "OECoreUpdateCatalogs": ["x86_64": directory + "cores.xml", "arm64": armDirectory + "cores.xml"],
        ]
        require(OECoreUpdateSecurity.publicKey(for: URL(string: directory + "nestopia.xml")!, architecture: "x86_64", metadata: metadata) == publicKey, "Own catalog lost its trusted key")
        let disallowed = [
            "https://evil.example.test/communism420/OpenEmu-Reborn/main/Updates/x86_64/nestopia.xml",
            directory.replacingOccurrences(of: "OpenEmu-Reborn", with: "Another-Repository") + "nestopia.xml",
            directory + "nested/nestopia.xml",
            directory + "../arm64/nestopia.xml",
            directory + "%2e%2e/arm64/nestopia.xml",
            directory.replacingOccurrences(of: "https:", with: "http:") + "nestopia.xml",
            directory.replacingOccurrences(of: "raw.githubusercontent.com", with: "raw.githubusercontent.com.evil.example.test") + "nestopia.xml",
            directory.replacingOccurrences(of: "raw.githubusercontent.com", with: "raw.githubusercontent.com:8443") + "nestopia.xml",
            directory.replacingOccurrences(of: "raw.githubusercontent.com", with: "user@raw.githubusercontent.com") + "nestopia.xml",
            directory + "nestopia.xml#fragment",
            "file:///tmp/nestopia.xml",
            armDirectory + "nestopia.xml",
        ]
        for value in disallowed {
            require(OECoreUpdateSecurity.publicKey(for: URL(string: value)!, architecture: "x86_64", metadata: metadata) == nil, "Trusted key escaped its catalog family: \(value)")
        }
        require(OECoreUpdateSecurity.catalogURL(architecture: "i386", metadata: metadata) == nil, "Unsupported architecture received a catalog")
        require(OECoreUpdateSecurity.publicKey(for: URL(string: directory + "nestopia.xml")!, metadata: [:]) == nil, "Missing app trust metadata was accepted")
        print("PASS: catalog trust cannot redirect to another host, path, port, scheme or processor family")

        let link = root.appendingPathComponent("archive-symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archiveURL)
        rejects("symbolic link archive") { try valid.verifyArchive(at: link) }
        rejects("non-RSS XML", expected: .invalidMetadata) { _ = try CoreAppcastItem.parse(Data("<error/>".utf8), publicKey: publicKey) }
        rejects("invalid minimum OS", expected: .invalidMetadata) { _ = try CoreAppcastItem.parse(feed(item(minimum: "not-a-version", signature: signature, length: "4096")), publicKey: publicKey) }
        rejects("blank version", expected: .invalidMetadata) { _ = try CoreAppcastItem.parse(feed(item(version: " ", signature: signature, length: "4096")), publicKey: publicKey) }
        print("PASS: invalid file type, document shape and version metadata fail closed")
    }
}
