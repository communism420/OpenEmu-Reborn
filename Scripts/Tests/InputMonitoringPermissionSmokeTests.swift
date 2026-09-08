// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-2-Clause

import AppKit

// The production permission methods are compiled by the companion script.
// Their collaborators below are memory-only: no HID manager, real preferences,
// permission request, application window, keyboard events or TCC operation exists.
enum FixtureAccess { case granted, denied, unknown }

@MainActor
final class OEDeviceManager {
    static var shared = OEDeviceManager()
    var accessType = FixtureAccess.granted
    var statusAfterRequest: FixtureAccess?
    var requests = 0
    var rescans = 0

    func requestAccess() -> Bool {
        requests += 1
        if let statusAfterRequest { accessType = statusAfterRequest }
        return accessType == .granted
    }
    func rescanKeyboardDevices() { rescans += 1 }
}

@MainActor
final class OEPreferences {
    static var shared = OEPreferences()
    var values = [String: Bool]()
    func bool(forKey key: String) -> Bool { values[key] ?? false }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

final class OEBindingsController {}

@MainActor
final class OEAlert {
    static let OEInputMonitoringAlertSuppressionKey = "OEInputMonitoringAlertSuppressed"
    static var presented = [OEAlert]()
    var messageText = ""
    var informativeText = ""
    var defaultButtonTitle = ""
    var alternateButtonTitle = ""
    var otherButtonTitle = ""
    var completion: ((NSApplication.ModalResponse) -> Void)?
    var closed = false
    var beginCount = 0
    var closeCount = 0
    private var otherButtonAction: Selector?
    private weak var otherButtonTarget: NSObject?

    func setOtherButtonAction(_ action: Selector?, andTarget target: AnyObject?) {
        otherButtonAction = action
        otherButtonTarget = target as? NSObject
    }

    func clickOtherButton() {
        guard let otherButtonAction, let otherButtonTarget else {
            preconditionFailure("Check Again must have its own action instead of ending the sheet")
        }
        _ = otherButtonTarget.perform(otherButtonAction, with: nil)
    }

    func beginSheetModal(for window: NSObject, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        beginCount += 1
        completion = completionHandler
        Self.presented.append(self)
    }

    func close(withResult result: NSApplication.ModalResponse) {
        closeCount += 1
        closed = true
        let handler = completion
        completion = nil
        handler?(result)
    }
}

@MainActor
final class FixtureWindowController {
    var window: NSObject? = NSObject()
}

@MainActor
final class PermissionTestDelegate: NSObject {
    var hidSupportIsSetUp = false
    var inputMonitoringPermissionsAlert: OEAlert?
    let mainWindowController = FixtureWindowController()
    func updateEventHandlers() {}
}

@main
@MainActor
enum InputMonitoringPermissionSmokeTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(EXIT_FAILURE)
        }
        print("PASS: \(message)")
    }

    static func fixture(_ status: FixtureAccess) -> PermissionTestDelegate {
        OEDeviceManager.shared = OEDeviceManager()
        OEDeviceManager.shared.accessType = status
        OEPreferences.shared = OEPreferences()
        OEAlert.presented = []
        return PermissionTestDelegate()
    }

    static func drainPresentationQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    static func main() async {
        let granted = fixture(.granted)
        // Settings were reset, and no keyboard event has ever been observed.
        granted.setUpHIDSupport()
        await drainPresentationQueue()
        require(OEDeviceManager.shared.requests == 0 && OEAlert.presented.isEmpty,
                "granted after settings reset: no permission request or warning without any key press")
        require(OEDeviceManager.shared.rescans > 0, "granted permission still refreshes keyboard delivery")
        require(OEPreferences.shared.values["OEInputMonitoringPreviouslyGranted"] == nil,
                "OS authorization is not copied into the settings file")

        for changedStatus in [FixtureAccess.granted, .unknown] {
            let changed = fixture(.denied)
            changed.setUpHIDSupport()
            OEDeviceManager.shared.accessType = changedStatus
            await drainPresentationQueue()
            require(OEAlert.presented.isEmpty && OEPreferences.shared.values.isEmpty,
                    "denied → \(changedStatus) before queued presentation: no stale warning or suppression write")
        }

        let denied = fixture(.denied)
        denied.setUpHIDSupport()
        await drainPresentationQueue()
        require(OEDeviceManager.shared.requests == 0 && OEAlert.presented.count == 1,
                "actual denial is reported honestly without requesting or resetting permission")
        let deniedAlert = OEAlert.presented[0]
        require(deniedAlert.otherButtonTitle == "Check Again", "automatic warning offers a non-destructive recheck")
        denied.showInputMonitoringPermissionsAlert()
        require(OEAlert.presented.count == 1, "one denial does not create duplicate sheets")
        OEDeviceManager.shared.accessType = .granted
        denied.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        require(deniedAlert.closed && denied.inputMonitoringPermissionsAlert == nil,
                "returning with a granted status dismisses the obsolete warning")
        require(OEDeviceManager.shared.rescans > 0 && OEDeviceManager.shared.requests == 0,
                "reactivation refreshes devices without requesting the existing permission")

        let retry = fixture(.denied)
        retry.setUpHIDSupport()
        await drainPresentationQueue()
        let retryAlert = OEAlert.presented[0]
        OEDeviceManager.shared.accessType = .granted
        retryAlert.clickOtherButton()
        await drainPresentationQueue()
        require(OEAlert.presented.count == 1 && retryAlert.beginCount == 1 && retryAlert.closeCount == 1 &&
                retry.inputMonitoringPermissionsAlert == nil && OEDeviceManager.shared.requests == 0,
                "Check Again reads a new grant and closes the same sheet exactly once without another request or reset")
        retry.refreshInputMonitoringPermissionStatus()
        require(retryAlert.closeCount == 1, "a repeated granted refresh never closes the sheet twice")

        let stillDenied = fixture(.denied)
        stillDenied.setUpHIDSupport()
        await drainPresentationQueue()
        let unchangedAlert = OEAlert.presented[0]
        let unchangedPreferences = OEPreferences.shared.values
        for _ in 0..<5 {
            unchangedAlert.clickOtherButton()
            await drainPresentationQueue()
            require(stillDenied.inputMonitoringPermissionsAlert === unchangedAlert &&
                    OEAlert.presented.count == 1 && unchangedAlert.beginCount == 1 && unchangedAlert.closeCount == 0 &&
                    !unchangedAlert.closed,
                    "repeated denied Check Again keeps the exact same open sheet without end/begin or flicker")
        }
        require(OEDeviceManager.shared.requests == 0 && OEDeviceManager.shared.rescans == 0 &&
                OEPreferences.shared.values == unchangedPreferences,
                "denied rechecks do not change authorization, suppression settings or device delivery")
        OEDeviceManager.shared.accessType = .granted
        unchangedAlert.clickOtherButton()
        await drainPresentationQueue()
        require(unchangedAlert.closeCount == 1 && OEAlert.presented.count == 1 &&
                stillDenied.inputMonitoringPermissionsAlert == nil && OEDeviceManager.shared.rescans == 1,
                "a later grant closes the repeatedly checked original sheet once and refreshes devices")

        let unknown = fixture(.unknown)
        OEPreferences.shared.values["OEInputMonitoringPreviouslyGranted"] = true
        OEDeviceManager.shared.statusAfterRequest = .granted
        unknown.setUpHIDSupport()
        await drainPresentationQueue()
        require(OEDeviceManager.shared.requests == 1 && OEAlert.presented.isEmpty,
                "unknown status asks the OS once instead of trusting a stale saved grant")
        require(OEDeviceManager.shared.rescans > 0, "grant returned by the OS enables a device refresh")

        let noWindow = fixture(.denied)
        noWindow.mainWindowController.window = nil
        noWindow.setUpHIDSupport()
        await drainPresentationQueue()
        require(OEAlert.presented.isEmpty && OEPreferences.shared.values.isEmpty,
                "no available host window does not permanently suppress an unshown warning")

        let earlyActivation = fixture(.granted)
        earlyActivation.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        require(OEDeviceManager.shared.requests == 0 && OEDeviceManager.shared.rescans == 0,
                "startup activation cannot initialize keyboard monitoring before setup")
        print("PASS: actual AppDelegate permission methods with memory-only collaborators; no real TCC access")
    }
}
