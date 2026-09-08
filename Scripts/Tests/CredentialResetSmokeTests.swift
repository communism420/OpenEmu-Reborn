// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import CryptoKit

// Keep the actual credential implementation isolated from the user's selected
// data folder. This test executable never launches OpenEmu or imports its SDK.
extension URL {
    static var oeApplicationSupportDirectory: URL {
        URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }
}

extension FileManager {
    func oeCreateDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }
}

@main
enum CredentialResetSmokeTests {
    enum ExpectedFailure: Error { case cancelled }

    static func main() throws {
        let root = URL.oeApplicationSupportDirectory
        let file = root.appendingPathComponent(".oe_credentials")
        let store = OECredentialStore.shared

        if CommandLine.arguments[2] == "restart" {
            // The preceding process saved a valid encrypted empty dictionary.
            // Existing ciphertext prevents any legacy Keychain migration.
            precondition(FileManager.default.fileExists(atPath: file.path))
            for key in OECredentialKey.allCases { precondition(store.get(key) == nil) }
            print("PASS: a fresh process reads an empty credential store")
            return
        }

        // Preparing a confirmation must not create/load the store or freeze it.
        // Discarding this ciphertext models cancelling the deletion dialog.
        precondition(!FileManager.default.fileExists(atPath: file.path))
        let preparedBeforeLoad = try store.makeEmptyStoreData()
        precondition(!preparedBeforeLoad.isEmpty)
        _ = try AES.GCM.SealedBox(combined: preparedBeforeLoad)
        precondition(!FileManager.default.fileExists(atPath: file.path))

        if CommandLine.arguments[2] == "loaded" {
            // Capture valid ciphertext without loading credentials or committing
            // a reset, then seed only synthetic test values through the real API.
            var emptyCiphertext = Data()
            do {
                try store.resetForTermination { data in
                    emptyCiphertext = data
                    throw ExpectedFailure.cancelled
                }
                preconditionFailure("A failed reset must report its error")
            } catch ExpectedFailure.cancelled {}
            try emptyCiphertext.write(to: file, options: .atomic)
            store.set("synthetic-before-reset", forKey: .screenScraperPassword)
            let originalFile = try Data(contentsOf: file)
            let preparedWithSavedLogin = try store.makeEmptyStoreData()
            precondition(!preparedWithSavedLogin.isEmpty)
            _ = try AES.GCM.SealedBox(combined: preparedWithSavedLogin)
            precondition(store.get(.screenScraperPassword) == "synthetic-before-reset")
            let fileBeforeConfirmation = try Data(contentsOf: file)
            precondition(fileBeforeConfirmation == originalFile)
            do {
                try store.resetForTermination { _ in throw ExpectedFailure.cancelled }
                preconditionFailure("A failed commit must report its error")
            } catch ExpectedFailure.cancelled {}
            precondition(store.get(.screenScraperPassword) == "synthetic-before-reset")
            let fileAfterFailure = try Data(contentsOf: file)
            precondition(fileAfterFailure == originalFile)
            _ = try store.makeEmptyStoreData()
            precondition(store.get(.screenScraperPassword) == "synthetic-before-reset")
            let fileAfterCancelledPreparation = try Data(contentsOf: file)
            precondition(fileAfterCancelledPreparation == originalFile)
            store.set("synthetic-after-cancellation", forKey: .screenScraperPassword)
            precondition(store.get(.screenScraperPassword) == "synthetic-after-cancellation")
        } else {
            precondition(!FileManager.default.fileExists(atPath: file.path))
        }

        var commits = 0
        try store.resetForTermination { data in
            try data.write(to: file, options: .atomic)
            commits += 1
        }
        precondition(commits == 1)
        let resetFile = try Data(contentsOf: file)
        for key in OECredentialKey.allCases {
            precondition(store.get(key) == nil)
            store.set("synthetic-late-write", forKey: key)
            store.remove(key)
            precondition(store.get(key) == nil)
        }
        try store.resetForTermination { _ in commits += 1 }
        precondition(commits == 1)
        let fileAfterLateWrites = try Data(contentsOf: file)
        precondition(fileAfterLateWrites == resetFile)
        print("PASS: empty-store preparation does not change credentials, disk or cancellation behavior")
        print("PASS: credential reset, commit failure, repeat reset and late-write protection")
    }
}
