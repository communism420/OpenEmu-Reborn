// Copyright (c) 2026, OpenEmu Team
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

import CryptoKit
import Foundation
import Sparkle.SUStandardVersionComparator

enum OECoreUpdateSecurity {
    static let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    static let maximumArchiveLength: Int64 = 1_073_741_824

    static var runningArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
#error("Core updates require arm64 or x86_64.")
#endif
    }

    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false &&
        url.user == nil && url.password == nil && url.fragment == nil
    }

    static func isSystemVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(components.count) && components.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && Int($0) != nil
        }
    }

    static func catalogURL(architecture: String = runningArchitecture,
                           metadata: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> URL? {
        guard ["arm64", "x86_64"].contains(architecture),
              let catalogs = metadata["OECoreUpdateCatalogs"] as? [String: String],
              let value = catalogs[architecture], let url = URL(string: value), isHTTPS(url) else { return nil }
        return url
    }

    /// Trust comes from the signed application, never from downloaded XML or a
    /// plugin's mutable Info.plist. A catalog cannot redirect us to another feed family.
    static func publicKey(for feedURL: URL,
                          architecture: String = runningArchitecture,
                          metadata: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> String? {
        guard let catalog = catalogURL(architecture: architecture, metadata: metadata),
              isHTTPS(feedURL), feedURL.host == catalog.host, feedURL.port == catalog.port,
              feedURL.deletingLastPathComponent().standardized == catalog.deletingLastPathComponent().standardized,
              let encoded = metadata["SUPublicEDKey"] as? String,
              let key = Data(base64Encoded: encoded), key.count == 32 else { return nil }
        return encoded
    }

    enum ValidationError: LocalizedError {
        case untrustedFeed, invalidMetadata, invalidSignature, unexpectedLength, badResponse

        var errorDescription: String? {
            switch self {
            case .untrustedFeed:
                NSLocalizedString("This core update feed is not trusted by this copy of OpenEmu Reborn.", comment: "")
            case .invalidMetadata:
                NSLocalizedString("The core update is missing valid signature, size, or processor information.", comment: "")
            case .invalidSignature:
                NSLocalizedString("The core update signature is invalid. Nothing has been installed.", comment: "")
            case .unexpectedLength:
                NSLocalizedString("The downloaded core archive has an unexpected size. Nothing has been installed.", comment: "")
            case .badResponse:
                NSLocalizedString("The core update server did not return a successful HTTPS response.", comment: "")
            }
        }
    }
}

struct CoreAppcastItem {
    let version: String
    let fileURL: URL
    let minimumSystemVersion: String
    let pubDate: Date?
    let signature: String
    let contentLength: Int64
    let signingPublicKey: String
    let architectures: Set<String>

    init(url: URL, version: String, minOSVersion: String, pubDate: String? = nil,
         signature: String, contentLength: Int64, signingPublicKey: String, architectures: Set<String>) {
        fileURL = url
        self.version = version
        minimumSystemVersion = minOSVersion
        self.signature = signature
        self.contentLength = contentLength
        self.signingPublicKey = signingPublicKey
        self.architectures = architectures
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "E, d MMM yyyy HH:mm:ss Z"
        self.pubDate = pubDate.flatMap { formatter.date(from: $0) }
    }

    var isSupported: Bool {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return supports(architecture: OECoreUpdateSecurity.runningArchitecture,
                        osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }

    func supports(architecture: String, osVersion: String) -> Bool {
        architectures.contains(architecture) &&
        SUStandardVersionComparator.default.compareVersion(minimumSystemVersion, toVersion: osVersion) != .orderedDescending
    }

    /// Ed25519 authenticates the original bytes before any archive extraction or
    /// compatibility signing. Ad-hoc codesign is not an authenticity check.
    func verifyArchive(at url: URL) throws {
        guard let signatureData = Data(base64Encoded: signature), signatureData.count == 64,
              let keyData = Data(base64Encoded: signingPublicKey), keyData.count == 32,
              contentLength > 0, contentLength <= OECoreUpdateSecurity.maximumArchiveLength else {
            throw OECoreUpdateSecurity.ValidationError.invalidMetadata
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw OECoreUpdateSecurity.ValidationError.invalidMetadata
        }
        guard let length = attributes[.size] as? NSNumber, length.int64Value == contentLength else {
            throw OECoreUpdateSecurity.ValidationError.unexpectedLength
        }
        let archive = try Data(contentsOf: url, options: .mappedIfSafe)
        guard archive.count == contentLength else { throw OECoreUpdateSecurity.ValidationError.unexpectedLength }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        guard key.isValidSignature(signatureData, for: archive) else {
            throw OECoreUpdateSecurity.ValidationError.invalidSignature
        }
    }

    static func parse(_ data: Data, publicKey: String) throws -> [CoreAppcastItem] {
        guard Data(base64Encoded: publicKey)?.count == 32 else {
            throw OECoreUpdateSecurity.ValidationError.untrustedFeed
        }
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement(), root.name == "rss",
              root.elements(forName: "channel").count == 1,
              let elements = try document.nodes(forXPath: "/rss/channel/item") as? [XMLElement] else {
            throw OECoreUpdateSecurity.ValidationError.invalidMetadata
        }
        let ns = OECoreUpdateSecurity.sparkleNamespace
        var result: [CoreAppcastItem] = []
        for item in elements {
            guard let enclosure = item.elements(forName: "enclosure").first,
                  let location = enclosure.attribute(forName: "url")?.stringValue,
                  let url = URL(string: location), OECoreUpdateSecurity.isHTTPS(url),
                  let version = enclosure.attribute(forLocalName: "version", uri: ns)?.stringValue, !version.isEmpty,
                  version.trimmingCharacters(in: .whitespacesAndNewlines) == version,
                  version.rangeOfCharacter(from: .controlCharacters) == nil,
                  let minimum = item.elements(forLocalName: "minimumSystemVersion", uri: ns).first?.stringValue,
                  OECoreUpdateSecurity.isSystemVersion(minimum),
                  let signature = enclosure.attribute(forLocalName: "edSignature", uri: ns)?.stringValue,
                  Data(base64Encoded: signature)?.count == 64,
                  let lengthText = enclosure.attribute(forName: "length")?.stringValue,
                  let length = Int64(lengthText), length > 0, length <= OECoreUpdateSecurity.maximumArchiveLength,
                  let hardware = item.elements(forLocalName: "hardwareRequirements", uri: ns).first?.stringValue else {
                throw OECoreUpdateSecurity.ValidationError.invalidMetadata
            }
            let architectures = Set(hardware.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init))
            guard !architectures.isEmpty, architectures.isSubset(of: ["arm64", "x86_64"]) else {
                throw OECoreUpdateSecurity.ValidationError.invalidMetadata
            }
            result.append(CoreAppcastItem(url: url, version: version, minOSVersion: minimum,
                                         pubDate: item.elements(forName: "pubDate").first?.stringValue,
                                         signature: signature, contentLength: length, signingPublicKey: publicKey,
                                         architectures: architectures))
        }
        return result.sorted {
            SUStandardVersionComparator.default.compareVersion($0.version, toVersion: $1.version) == .orderedDescending
        }
    }
}
