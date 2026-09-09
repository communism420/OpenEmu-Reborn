#!/usr/bin/env swift
// Verify an update archive using only the public Ed25519 key embedded in the
// app. This does not read the Keychain or create/sign an update.
import CryptoKit
import Foundation

do {
    guard CommandLine.arguments.count == 4,
          let key = Data(base64Encoded: CommandLine.arguments[2]), key.count == 32,
          let signature = Data(base64Encoded: CommandLine.arguments[3]), signature.count == 64 else {
        throw NSError(domain: "OpenEmuUpdateSignature", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected archive, base64 public key and base64 signature"])
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    guard publicKey.isValidSignature(signature, for: data) else {
        throw NSError(domain: "OpenEmuUpdateSignature", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Archive signature does not match the app's Sparkle public key"])
    }
    print("PASS: archive EdDSA signature matches the app's public key")
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
    exit(1)
}
