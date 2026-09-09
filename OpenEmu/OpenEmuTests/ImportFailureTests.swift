// Copyright (c) 2023, OpenEmu Team
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

import XCTest
import UserNotifications
import OpenEmuBase
@testable import OpenEmu
@testable import OpenEmuSystem

class ImportFailureTests: XCTestCase, ROMImporterDelegate {
    
    var expectations: [String: XCTestExpectation] = [:]
    
    var disallowArchivedFileError: Int?
    var emptyFileError: Int?
    var noSystemError: Int?
    var missingFilesError: Int?
    var cueSheetError: Bool?
    var notPlainTextFileError: Int?

    @MainActor
    private func assertHostedStartupIsIsolated() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        XCTAssertTrue(OEDataFolderSetup.isRunningUnitTests)
        XCTAssertTrue(delegate.libraryLoaded)
        XCTAssertNotNil(OELibraryDatabase.default?.importer)
        // A fresh test library must not be marked as already set up just to
        // avoid the assistant. It must never open that assistant at all.
        XCTAssertFalse(OEPreferences.shared.bool(forKey: SetupAssistant.hasFinishedKey))
        XCTAssertFalse(delegate.mainWindowController.isWindowLoaded)
        XCTAssertFalse(delegate.preferencesWindowController.isWindowLoaded)
        XCTAssertTrue(delegate.startupQueue.isEmpty)
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible && $0.attachedSheet == nil })
        XCTAssertNil(delegate.hidEventsMonitor)
        XCTAssertNil(delegate.keyboardEventsMonitor)
        XCTAssertNil(delegate.unhandledEventsMonitor)
        XCTAssertNil(UNUserNotificationCenter.current().delegate)
        // Sparkle documents this command-line override for hosted tests. It
        // must not change the persistent preferences of ordinary launches.
        XCTAssertNotNil(UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["SUEnableAutomaticChecks"])
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks"))
        XCTAssertFalse(delegate.applicationShouldOpenUntitledFile(NSApp))
        XCTAssertFalse(delegate.mainWindowController.isWindowLoaded)
    }

    @MainActor
    func testHostedStartupIsIsolated() throws {
        try assertHostedStartupIsIsolated()
    }
    
    @MainActor
    @available(macOS 13.0, *)
    func testBundleResources() throws {
        try assertHostedStartupIsIsolated()
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Import Failure Test Files/")
        
        let importer = try XCTUnwrap(OELibraryDatabase.default?.importer)
        importer.delegate = self
        
        let testFiles = [
            "compression_verboten.zip",
            "contains_no_data.zip",
            "cue_sheet_missing_file.cue",
            "cue_sheet_not_plain_text.cue",
            "cue_sheet_wrong_syntax.cue",
            "no_valid_system.iso",
        ]
        
        for fileName in testFiles {
            let fileURL = url.appending(path: fileName)
            expectations[fileName] = expectation(description: fileName)
            XCTAssertTrue(importer.importItem(at: fileURL))
        }
        
        importer.start()
        
        waitForExpectations(timeout: 10)
        try assertHostedStartupIsIsolated()
        
        XCTAssertEqual(disallowArchivedFileError, OEImportErrorCode.disallowArchivedFile.rawValue)
        XCTAssertEqual(emptyFileError, OEImportErrorCode.emptyFile.rawValue)
        XCTAssertEqual(noSystemError, OEImportErrorCode.noSystem.rawValue)
        XCTAssertEqual(missingFilesError, OEDiscDescriptorErrors.missingFilesError.rawValue)
        XCTAssertEqual(notPlainTextFileError, OEDiscDescriptorErrors.notPlainTextFileError.rawValue)
        XCTAssertTrue(try XCTUnwrap(cueSheetError))
        XCTAssertEqual(noSystemError, OEImportErrorCode.noSystem.rawValue)
    }
    
    func romImporter(_ importer: ROMImporter, stoppedProcessingItem item: ImportOperation) {
        guard let error = item.error as? NSError else { return }
        let fileName = item.url.lastPathComponent
        switch fileName {
        case "compression_verboten.zip":
            disallowArchivedFileError = error.code
            expectations.removeValue(forKey: fileName)?.fulfill()
        case "contains_no_data.zip":
            emptyFileError = error.code
            expectations.removeValue(forKey: fileName)?.fulfill()
        case "cue_sheet_missing_file.cue":
            missingFilesError = error.code
            expectations.removeValue(forKey: fileName)?.fulfill()
        case "cue_sheet_not_plain_text.cue":
            notPlainTextFileError = error.code
            expectations.removeValue(forKey: fileName)?.fulfill()
        case "cue_sheet_wrong_syntax.cue":
            cueSheetError = error is OECUESheetErrors
            expectations.removeValue(forKey: fileName)?.fulfill()
        case "no_valid_system.iso":
            noSystemError = error.code
            expectations.removeValue(forKey: fileName)?.fulfill()
        default:
            break
        }
    }
}
