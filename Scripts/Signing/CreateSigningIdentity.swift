// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-3-Clause
// Maintainer-only utility. Never linked into OpenEmu or run at app startup.
// The private key is generated in the login keychain and is never exported.
// This tool does not change certificate trust, TCC, or codesign's access rights.

import CryptoKit
import Darwin
import Foundation
import Security

private enum Configuration {
    static let label = "OpenEmu-Intel Local Signing"
    static let tag = Data("org.openemu.OpenEmu-Intel.local-code-signing.v1".utf8)
    static let keySize = 3072
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
}

private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == errSecSuccess else {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        throw Failure("\(operation): \(reason) (\(status))")
    }
}

// Only the public certificate and public key are encoded here. All cryptographic
// signing is performed by Security using a SecKey reference, not private bytes.
private enum DER {
    static func value(_ tag: UInt8, _ body: Data) -> Data {
        var length = body.count
        var encoded = Data()
        if length < 128 {
            encoded.append(UInt8(length))
        } else {
            var bytes = [UInt8]()
            while length > 0 { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 }
            encoded.append(0x80 | UInt8(bytes.count))
            encoded.append(contentsOf: bytes)
        }
        return Data([tag]) + encoded + body
    }

    static func sequence(_ fields: Data...) -> Data { value(0x30, fields.reduce(Data(), +)) }
    static func integer(_ input: Data) -> Data {
        var bytes = Array(input)
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return value(0x02, Data(bytes))
    }
    static func bits(_ input: Data) -> Data { value(0x03, Data([0]) + input) }
    static func oid(_ bytes: [UInt8]) -> Data { value(0x06, Data(bytes)) }

    static var signatureAlgorithm: Data {
        sequence(oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]), Data([0x05, 0]))
    }
    static var name: Data {
        sequence(value(0x31, sequence(oid([0x55, 0x04, 0x03]), value(0x0c, Data(Configuration.label.utf8)))))
    }
    static var extensions: Data {
        // basicConstraints: critical, CA=false (the omitted DEFAULT is false).
        let basic = sequence(oid([0x55, 0x1d, 0x13]), Data([0x01, 0x01, 0xff]), value(0x04, sequence()))
        // keyUsage: critical, digitalSignature only (seven unused bits).
        let usage = sequence(oid([0x55, 0x1d, 0x0f]), Data([0x01, 0x01, 0xff]), value(0x04, value(0x03, Data([7, 0x80]))))
        let extended = sequence(oid([0x55, 0x1d, 0x25]), value(0x04, sequence(oid([0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03]))))
        return value(0xa3, sequence(basic, usage, extended))
    }
    static func publicKeyInfo(_ pkcs1: Data) -> Data {
        sequence(sequence(oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]), Data([0x05, 0])), bits(pkcs1))
    }
    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        let utc = (1950..<2050).contains(year)
        formatter.dateFormat = utc ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return value(utc ? 0x17 : 0x18, Data(formatter.string(from: date).utf8))
    }

    struct Node {
        let tag: UInt8
        let encoded: Data
        let body: Data
    }
    static func children(_ data: Data) throws -> [Node] {
        let bytes = Array(data)
        var index = 0
        var result = [Node]()
        while index < bytes.count {
            let start = index
            let tag = bytes[index]
            index += 1
            try require(index < bytes.count, "Truncated DER length")
            var length = Int(bytes[index])
            index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                try require(count > 0 && count <= 4 && count <= bytes.count - index, "Invalid DER length")
                try require(bytes[index] != 0, "Noncanonical DER length")
                length = 0
                for _ in 0..<count { length = (length << 8) | Int(bytes[index]); index += 1 }
                try require(length >= 128, "Noncanonical DER length")
            }
            try require(length <= bytes.count - index, "Truncated DER value")
            let body = Data(bytes[index..<(index + length)])
            index += length
            result.append(Node(tag: tag, encoded: Data(bytes[start..<index]), body: body))
        }
        return result
    }
}

private func publicBytes(_ privateKey: SecKey) throws -> Data {
    guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw Failure("Cannot derive the public key") }
    var error: Unmanaged<CFError>?
    // This is deliberately the PUBLIC key. Never export the private SecKey.
    guard let bytes = SecKeyCopyExternalRepresentation(publicKey, &error) else {
        throw Failure("Cannot encode the public key: \(String(describing: error?.takeRetainedValue()))")
    }
    return bytes as Data
}

private func makeCertificate(privateKey: SecKey, now: Date = Date()) throws -> Data {
    var serial = [UInt8](repeating: 0, count: 20)
    try check(SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial), "Generate public serial number")
    serial[0] &= 0x7f
    if serial.allSatisfy({ $0 == 0 }) { serial[0] = 1 }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let expires = calendar.date(byAdding: .year, value: 10, to: now) else { throw Failure("Cannot calculate certificate expiry") }
    let tbs = DER.sequence(
        DER.value(0xa0, DER.integer(Data([2]))), DER.integer(Data(serial)),
        DER.signatureAlgorithm, DER.name,
        DER.sequence(DER.time(now.addingTimeInterval(-300)), DER.time(expires)),
        DER.name, DER.publicKeyInfo(try publicBytes(privateKey)), DER.extensions
    )
    try require(SecKeyIsAlgorithmSupported(privateKey, .sign, .rsaSignatureMessagePKCS1v15SHA256), "RSA SHA-256 signing is unavailable")
    var error: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) else {
        throw Failure("Certificate signing was cancelled or failed: \(String(describing: error?.takeRetainedValue()))")
    }
    return DER.sequence(tbs, DER.signatureAlgorithm, DER.bits(signature as Data))
}

private func certificateDate(_ node: DER.Node) throws -> Date {
    try require(node.tag == 0x17 || node.tag == 0x18, "Unsupported certificate time")
    guard let text = String(data: node.body, encoding: .ascii) else { throw Failure("Invalid certificate time") }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.isLenient = false
    formatter.twoDigitStartDate = Date(timeIntervalSince1970: -631152000) // 1950-01-01
    formatter.dateFormat = node.tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
    guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
        throw Failure("Invalid certificate time")
    }
    return date
}

@discardableResult
private func validateCertificate(_ data: Data, privateKey: SecKey, now: Date = Date()) throws -> SecCertificate {
    let outer = try DER.children(data)
    try require(outer.count == 1 && outer[0].tag == 0x30, "Invalid certificate envelope")
    let fields = try DER.children(outer[0].body)
    try require(fields.count == 3 && fields[0].tag == 0x30 && fields[1].encoded == DER.signatureAlgorithm,
                "Unexpected certificate signature algorithm")
    try require(fields[2].tag == 0x03 && fields[2].body.first == 0 && fields[2].body.count > 1, "Invalid certificate signature")
    let tbs = try DER.children(fields[0].body)
    try require(tbs.count == 8 && tbs[0].encoded == DER.value(0xa0, DER.integer(Data([2]))), "Unexpected certificate layout")
    try require(tbs[1].tag == 0x02 && !tbs[1].body.isEmpty && tbs[1].body.count <= 20 && tbs[1].body.first! & 0x80 == 0,
                "Invalid certificate serial number")
    try require(tbs[2].encoded == DER.signatureAlgorithm && tbs[3].encoded == DER.name && tbs[5].encoded == DER.name,
                "The certificate is not the expected self-issued local identity")
    try require(tbs[6].encoded == DER.publicKeyInfo(try publicBytes(privateKey)), "Certificate does not match the stored private key")
    try require(tbs[7].encoded == DER.extensions, "Certificate is not a code-signing-only, non-CA certificate")
    try require(tbs[4].tag == 0x30, "Invalid validity period")
    let validity = try DER.children(tbs[4].body)
    try require(validity.count == 2, "Invalid validity period")
    let start = try certificateDate(validity[0])
    let end = try certificateDate(validity[1])
    try require(start <= now && now < end, "The local certificate has expired or is not yet valid; it will not be silently replaced")
    guard let certificate = SecCertificateCreateWithData(nil, data as CFData),
          let publicKey = SecCertificateCopyKey(certificate) else { throw Failure("Security rejected the certificate") }
    var error: Unmanaged<CFError>?
    try require(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, fields[0].encoded as CFData,
                                     Data(fields[2].body.dropFirst()) as CFData, &error), "Certificate self-signature is invalid")
    try require(SecIdentityCreate(nil, certificate, privateKey) != nil, "Security rejected the certificate/private-key pairing")
    return certificate
}

// The user explicitly chose the file-based login keychain, not the separate
// data-protection keychain. Its supported APIs are deprecated but still needed
// for this narrowly scoped maintainer utility. No default/search list is changed.
private func loginKeychain() throws -> SecKeychain {
    try require(geteuid() != 0 && geteuid() == getuid(), "Run as the logged-in user, never with sudo")
    guard let entry = getpwuid(geteuid()), let directory = entry.pointee.pw_dir else { throw Failure("Cannot locate the current user's home") }
    let path = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        .appendingPathComponent("Library/Keychains/login.keychain-db").path
    var attributes = stat()
    try require(lstat(path, &attributes) == 0 && attributes.st_uid == geteuid() && (attributes.st_mode & S_IFMT) == S_IFREG,
                "The explicit user login keychain is missing, not owned by this user, or is a symlink")
    var keychain: SecKeychain?
    try check(SecKeychainOpen(path, &keychain), "Open the user login keychain")
    guard let keychain else { throw Failure("No login keychain reference") }
    return keychain
}

private func keys(in keychain: SecKeychain) throws -> [SecKey] {
    // The legacy provider applies the application tag after generating a key.
    // If that last metadata write failed, its initial label still identifies
    // the partial item. Refuse to create a second signer on a later retry.
    let namedQuery: [String: Any] = [
        kSecClass as String: kSecClassKey, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        kSecAttrLabel as String: Configuration.label,
        kSecMatchSearchList as String: [keychain], kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnAttributes as String: true
    ]
    var namedResult: CFTypeRef?
    let namedStatus = SecItemCopyMatching(namedQuery as CFDictionary, &namedResult)
    if namedStatus != errSecItemNotFound {
        try check(namedStatus, "Check only the local signing label for a partial key")
        guard let items = namedResult as? [[String: Any]] else { throw Failure("Unexpected local signing label query result") }
        try require(items.allSatisfy { ($0[kSecAttrApplicationTag as String] as? Data) == Configuration.tag },
                    "A key with the local signing label exists without the expected application tag; nothing will be created, replaced or deleted")
    }
    let query: [String: Any] = [
        kSecClass as String: kSecClassKey, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        kSecAttrApplicationTag as String: Configuration.tag,
        kSecMatchSearchList as String: [keychain], kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnRef as String: true
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    try check(status, "Find only the tagged local signing key")
    guard let found = result as? [SecKey] else { throw Failure("Unexpected signing-key query result") }
    return found
}

private func certificates(in keychain: SecKeychain) throws -> [SecCertificate] {
    let query: [String: Any] = [
        kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: Configuration.label,
        kSecMatchSearchList as String: [keychain], kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnRef as String: true
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    try check(status, "Find only the local signing certificate")
    guard let found = result as? [SecCertificate] else { throw Failure("Unexpected signing-certificate query result") }
    return found
}

private func requireNonextractable(_ key: SecKey) throws {
    // SecItem's file-based metadata omits Extractable. Request just this one
    // legacy attribute, explicitly omitting both data output parameters. This
    // does not export, wrap, copy or attempt to read private key material.
    var tag = UInt32(kSecKeyExtractable)
    var format = UInt32(CSSM_DB_ATTRIBUTE_FORMAT_UINT32)
    var list: UnsafeMutablePointer<SecKeychainAttributeList>?
    let status = withUnsafeMutablePointer(to: &tag) { tagPointer in
        withUnsafeMutablePointer(to: &format) { formatPointer in
            var info = SecKeychainAttributeInfo(count: 1, tag: tagPointer, format: formatPointer)
            // SecKey references returned by the file-based keychain are also
            // keychain item references, as required by this legacy API.
            return SecKeychainItemCopyAttributesAndData(unsafeBitCast(key, to: SecKeychainItem.self),
                                                       &info, nil, &list, nil, nil)
        }
    }
    defer { if let list { SecKeychainItemFreeAttributesAndData(list, nil) } }
    try check(status, "Read only the private key's nonextractability flag")
    guard let list, list.pointee.count == 1, let attribute = list.pointee.attr?.pointee,
          attribute.tag == UInt32(kSecKeyExtractable), attribute.length == MemoryLayout<UInt32>.size,
          let data = attribute.data else { throw Failure("Cannot verify the nonextractability attribute") }
    var extractable: UInt32 = 1
    memcpy(&extractable, data, MemoryLayout<UInt32>.size)
    try require(extractable == 0, "The stored private key is extractable; refusing to export or replace it")
}

private func validateStoredKey(_ key: SecKey, in keychain: SecKeychain) throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassKey, kSecMatchItemList as String: [key],
        kSecMatchSearchList as String: [keychain], kSecReturnAttributes as String: true
    ]
    var result: CFTypeRef?
    try check(SecItemCopyMatching(query as CFDictionary, &result), "Inspect the local signing key's attributes")
    guard let attributes = result as? [String: Any] else { throw Failure("Cannot verify private-key protection") }
    try require(attributes[kSecAttrLabel as String] as? String == Configuration.label &&
                attributes[kSecAttrApplicationTag as String] as? Data == Configuration.tag,
                "The existing tagged key has unexpected metadata; it will not be replaced")
    try require((attributes[kSecAttrKeySizeInBits as String] as? NSNumber)?.intValue == Configuration.keySize &&
                (attributes[kSecAttrIsPermanent as String] as? NSNumber)?.boolValue == true &&
                (attributes[kSecAttrCanSign as String] as? NSNumber)?.boolValue == true &&
                (attributes[kSecAttrCanVerify as String] as? NSNumber)?.boolValue == false &&
                (attributes[kSecAttrCanEncrypt as String] as? NSNumber)?.boolValue == false &&
                (attributes[kSecAttrCanDecrypt as String] as? NSNumber)?.boolValue == false &&
                (attributes[kSecAttrCanDerive as String] as? NSNumber)?.boolValue == false &&
                (attributes[kSecAttrCanWrap as String] as? NSNumber)?.boolValue == false &&
                (attributes[kSecAttrCanUnwrap as String] as? NSNumber)?.boolValue == false,
                "The stored key must report RSA-3072, permanent and signing-only; refusing to export or replace it")
    // The legacy provider does not implement kSecAttrIsSensitive at key
    // generation. Nonextractability is checked separately; do not claim the separate
    // Sensitive flag is set. Use item metadata, not a private-key data copy.
    // File-based keys can report legacy CSSM numeric constants, whereas modern
    // SecKey attributes use the corresponding numeric CFString constants.
    func numericName(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        return (value as? NSNumber)?.stringValue
    }
    try require(numericName(attributes[kSecAttrKeyType as String]) == kSecAttrKeyTypeRSA as String,
                "The stored key is not RSA")
    try require(numericName(attributes[kSecAttrKeyClass as String]) == kSecAttrKeyClassPrivate as String,
                "The stored key is not a private key")
    try requireNonextractable(key)
}

private func keyParameters(permanent: Bool) -> [String: Any] {
    // The file-based provider reads IsExtractable only at the top level. Its
    // public usage must match a sign-only private key: the default public
    // encrypt/derive capabilities otherwise cause errSecKeyUsageIncorrect.
    [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: Configuration.keySize,
        kSecAttrIsExtractable as String: false,
        kSecPrivateKeyAttrs as String: [
            kSecAttrIsPermanent as String: permanent,
            kSecAttrCanSign as String: true, kSecAttrCanVerify as String: false,
            kSecAttrCanEncrypt as String: false, kSecAttrCanDecrypt as String: false,
            kSecAttrCanDerive as String: false, kSecAttrCanWrap as String: false,
            kSecAttrCanUnwrap as String: false
        ],
        kSecPublicKeyAttrs as String: [
            kSecAttrIsPermanent as String: false,
            kSecAttrCanSign as String: false, kSecAttrCanVerify as String: true,
            kSecAttrCanEncrypt as String: false, kSecAttrCanDecrypt as String: false,
            kSecAttrCanDerive as String: false, kSecAttrCanWrap as String: false,
            kSecAttrCanUnwrap as String: false
        ]
    ]
}

private func createPrivateKey(in keychain: SecKeychain) throws -> SecKey {
    var access: SecAccess?
    // Empty, NOT nil: nobody (including codesign) receives silent access.
    try check(SecAccessCreate(Configuration.label as CFString, [] as CFArray, &access), "Create confirmation-only key access")
    guard let access else { throw Failure("Cannot create protected access settings") }
    var attributes = keyParameters(permanent: true)
    attributes[kSecUseKeychain as String] = keychain
    // SecAccess must also be top-level for the file-based provider.
    attributes[kSecAttrAccess as String] = access
    var privateAttributes = attributes[kSecPrivateKeyAttrs as String] as! [String: Any]
    privateAttributes[kSecAttrLabel as String] = Configuration.label
    privateAttributes[kSecAttrApplicationTag as String] = Configuration.tag
    attributes[kSecPrivateKeyAttrs as String] = privateAttributes
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
        throw Failure("Create private key: \(String(describing: error?.takeRetainedValue()))")
    }
    try validateStoredKey(key, in: keychain)
    return key
}

private func validateStoredIdentity(_ key: SecKey, certificate: SecCertificate, in keychain: SecKeychain) throws {
    try validateStoredKey(key, in: keychain)
    try validateCertificate(SecCertificateCopyData(certificate) as Data, privateKey: key)
    var identity: SecIdentity?
    try check(SecIdentityCreateWithCertificate(keychain, certificate, &identity), "Find the identity in the login keychain")
    guard let identity else { throw Failure("No matching keychain identity") }
    var identityKey: SecKey?
    try check(SecIdentityCopyPrivateKey(identity, &identityKey), "Verify the identity's key reference")
    guard let identityKey else { throw Failure("The identity has no key reference") }
    try require(try publicBytes(identityKey) == publicBytes(key), "The stored identity uses a different private key")
}

private func report(_ certificate: SecCertificate, state: String) {
    let bytes = SecCertificateCopyData(certificate) as Data
    // SHA-1 is only codesign's documented certificate selector, not a security check.
    print("status: \(state)")
    print("label: \(Configuration.label)")
    print("certificate SHA-1 (codesign selector): \(Insecure.SHA1.hash(data: bytes).map { String(format: "%02X", $0) }.joined())")
    print("certificate SHA-256: \(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())")
    print("No trust settings or macOS privacy permissions were changed.")
}

private final class PublicOutput {
    private let directory: Int32
    private let name: String
    init(_ path: String) throws {
        try require(path.hasPrefix("/") && (path as NSString).pathExtension.lowercased() == "cer", "Certificate output must be an absolute new .cer path")
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        guard let canonical = realpath(parent.path, nil) else { throw Failure("Cannot resolve certificate output directory") }
        defer { free(canonical) }
        try require(url.path == path && String(cString: canonical) == parent.path,
                    "Certificate output must not use symlinks or parent traversal")
        directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw Failure("Cannot open certificate output directory") }
        name = url.lastPathComponent
        var info = stat()
        guard fstat(directory, &info) == 0 && info.st_uid == geteuid() && info.st_mode & 0o022 == 0 else {
            close(directory)
            throw Failure("Certificate output directory must be owned by this user and not writable by others")
        }
        var existing = stat()
        guard fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT else {
            close(directory)
            throw Failure("Certificate output already exists; it will not be overwritten")
        }
    }
    deinit { close(directory) }
    func write(_ certificate: SecCertificate) throws {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure("Cannot exclusively create the public certificate output") }
        defer { close(fd) }
        let data = SecCertificateCopyData(certificate) as Data
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0 && errno == EINTR { continue }
                try require(amount > 0, "Cannot finish writing the public certificate")
                offset += amount
            }
        }
        try require(fsync(fd) == 0, "Cannot flush the public certificate")
    }
}

private final class CreationLease {
    private let descriptor: Int32
    init() throws {
        // Empty coordination file only. Keeping its inode avoids unlock/unlink
        // races between two invocations. It contains no key material.
        // Ignore TMPDIR: every invocation for this user must share one lock.
        let required = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        try require(required > 1 && required <= Int(PATH_MAX), "Cannot locate the operating system's user temporary directory")
        var temporaryPath = [CChar](repeating: 0, count: required)
        try require(confstr(_CS_DARWIN_USER_TEMP_DIR, &temporaryPath, required) == required,
                    "The operating system's user temporary directory changed")
        guard let canonical = realpath(temporaryPath, nil) else { throw Failure("Cannot resolve the user temporary directory") }
        defer { free(canonical) }
        let directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        var parent = stat()
        try require(lstat(directory.path, &parent) == 0 && parent.st_uid == geteuid() && parent.st_mode & 0o077 == 0,
                    "A private user temporary directory is required for creation")
        let path = directory.appendingPathComponent("OpenEmu-Intel-Local-Signing.lock").path
        descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure("Cannot acquire the signing-identity creation lock") }
        var info = stat()
        guard fstat(descriptor, &info) == 0 && info.st_uid == geteuid() && info.st_nlink == 1 &&
                info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o077 == 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw Failure("Another creator is running, or the creation lock is unsafe")
        }
        var current = stat()
        guard lstat(path, &current) == 0 && current.st_dev == info.st_dev && current.st_ino == info.st_ino else {
            close(descriptor)
            throw Failure("The creation lock was replaced; refusing to create a signing key")
        }
    }
    deinit { close(descriptor) }
}

private func selfTest(output: PublicOutput?) throws {
    // Exercise the same nonextractable, sign/verify-only usage as --create,
    // with neither key stored and without opening a keychain.
    let parameters = keyParameters(permanent: false)
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(parameters as CFDictionary, &error) else {
        throw Failure("Ephemeral key generation failed: \(String(describing: error?.takeRetainedValue()))")
    }
    let bytes = try makeCertificate(privateKey: key)
    let certificate = try validateCertificate(bytes, privateKey: key)
    var damaged = bytes
    damaged[damaged.count - 1] ^= 1
    do {
        try validateCertificate(damaged, privateKey: key)
        throw Failure("Self-test accepted a damaged self-signature")
    } catch let failure as Failure {
        try require(failure.description == "Certificate self-signature is invalid", "Unexpected damaged-signature test result: \(failure)")
    }
    do {
        try validateCertificate(bytes, privateKey: key, now: Date().addingTimeInterval(366 * 11 * 24 * 60 * 60))
        throw Failure("Self-test accepted an expired certificate")
    } catch let failure as Failure {
        try require(failure.description.hasPrefix("The local certificate has expired"), "Unexpected expiry test result: \(failure)")
    }
    try output?.write(certificate)
    report(certificate, state: "self-test passed (ephemeral key; no keychain writes)")
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let mode = arguments.first, ["--check", "--create", "--self-test"].contains(mode) else {
        throw Failure("Usage: CreateSigningIdentity --check | --create --certificate-output /absolute/new.cer | --self-test [--certificate-output /absolute/new.cer]")
    }
    let output: PublicOutput?
    if arguments.count == 3 && arguments[1] == "--certificate-output" && mode != "--check" {
        output = try PublicOutput(arguments[2])
    } else {
        try require(arguments.count == 1 && mode != "--create", "--create requires --certificate-output with a new absolute .cer path; --check is read-only")
        output = nil
    }
    if mode == "--self-test" { try selfTest(output: output); return }
    let keychain = try loginKeychain()
    let lease = mode == "--create" ? try CreationLease() : nil
    defer { withExtendedLifetime(lease) {} }
    var foundKeys = try keys(in: keychain)
    let foundCertificates = try certificates(in: keychain)
    try require(foundKeys.count <= 1 && foundCertificates.count <= 1, "Duplicate local signing items found; nothing will be replaced or deleted")
    if let certificate = foundCertificates.first {
        guard let key = foundKeys.first else { throw Failure("Local certificate exists without its tagged private key; refusing to create a new identity") }
        try validateStoredIdentity(key, certificate: certificate, in: keychain)
        try output?.write(certificate)
        report(certificate, state: "existing identity verified and reused")
        return
    }
    if mode == "--check" {
        print(foundKeys.isEmpty ? "status: missing" : "status: partial (tagged key exists; --create will reuse it)")
        if let key = foundKeys.first { try validateStoredKey(key, in: keychain) }
        return
    }
    if foundKeys.isEmpty {
        let key = try createPrivateKey(in: keychain)
        foundKeys = try keys(in: keychain)
        try require(foundKeys.count == 1 && (try publicBytes(foundKeys[0])) == publicBytes(key), "Cannot uniquely find the new key in the login keychain; nothing was deleted")
    }
    let key = foundKeys[0]
    try validateStoredKey(key, in: keychain)
    let data = try makeCertificate(privateKey: key)
    let certificate = try validateCertificate(data, privateKey: key)
    let add: [String: Any] = [kSecValueRef as String: certificate, kSecUseKeychain as String: keychain,
                              kSecAttrLabel as String: Configuration.label]
    try check(SecItemAdd(add as CFDictionary, nil), "Save the public certificate next to its existing private key")
    try validateStoredIdentity(key, certificate: certificate, in: keychain)
    try output?.write(certificate)
    report(certificate, state: "identity created (or partial identity completed)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error)\nIf a tagged key was already created, it is retained for a safe --create retry. No private key is exported or deleted.\n".utf8))
    exit(1)
}
