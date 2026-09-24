// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-2-Clause

import AppKit
import ApplicationServices
import ObjectiveC

// Override only this test process's public screen accessor. No actual display
// mode is changed. Native modal code sees the same smaller usable area as the
// production fitting code, including any late AppKit resize notifications.
extension NSScreen {
    @MainActor @objc fileprivate func oePanelTestVisibleFrame() -> NSRect {
        DataFolderPanelSmokeTests.visibleFrameOverride ?? oePanelTestVisibleFrame()
    }
}

@main @MainActor
struct DataFolderPanelSmokeTests {
    static var visibleFrameOverride: NSRect?
    static var failures: [String] = []
    static var nativeButtonSamples = 0
    static var unavailableButtonSamples = 0
    static var remoteButtons: [(String, CGRect)] = []
    static var activeScenario = ""
    static var nativePrompt = ""

    nonisolated static func externalButtons() -> ([(String, CGRect)], String) {
        guard AXIsProcessTrusted() else { return ([], "accessibility permission unavailable; no permission request made") }
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        var result: [(String, CGRect)] = []
        var error: AXError = .success
        let deadline = Date().addingTimeInterval(0.8)
        var visited = 0
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if status != .success { error = status }
            return value
        }
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 16, visited < 1000, Date() < deadline else { return }
            visited += 1
            if value(element, kAXRoleAttribute) as? String == kAXButtonRole,
               let title = value(element, kAXTitleAttribute) as? String,
               let rawPosition = value(element, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
               let rawSize = value(element, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() {
                var position = CGPoint.zero
                var size = CGSize.zero
                if AXValueGetValue(unsafeDowncast(rawPosition, to: AXValue.self), .cgPoint, &position),
                   AXValueGetValue(unsafeDowncast(rawSize, to: AXValue.self), .cgSize, &size) {
                    result.append((title, CGRect(origin: position, size: size)))
                }
            }
            for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(app, depth: 0)
        return (result, "AX trusted=\(AXIsProcessTrusted()), last status=\(error.rawValue)")
    }

    static func capture(_ panel: NSOpenPanel, scenario: String) {
        guard ProcessInfo.processInfo.environment["OE_PANEL_TEST_SCREENSHOTS"] == "YES",
              let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else { return }
        guard CGPreflightScreenCaptureAccess() else {
            report("NOTE: window screenshot unavailable without screen-recording permission; no permission request made")
            return
        }
        let path = URL(fileURLWithPath: home).appendingPathComponent(scenario.replacingOccurrences(of: "/", with: "-") + ".png")
        report("CAPTURE: windowNumber=\(panel.windowNumber), screen access=\(CGPreflightScreenCaptureAccess())")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // Capture only this fixture's known panel, never the whole desktop.
        process.arguments = ["-x", "-l", String(panel.windowNumber), path.path]
        do {
            try process.run()
            process.waitUntilExit()
            report(process.terminationStatus == 0 ? "SCREENSHOT: \(path.path)" : "NOTE: window screenshot unavailable")
        } catch { report("NOTE: window screenshot unavailable: \(error)") }
    }

    static func report(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message); report("FAIL: " + message) }
    }

    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    static func verifyButtons(_ buttons: [(String, NSRect)], in panel: NSOpenPanel, scenario: String) {
        for (index, button) in buttons.enumerated() {
            require(panel.frame.contains(button.1), "\(scenario) native '\(button.0)' remains inside the panel")
            for other in buttons.dropFirst(index + 1) {
                require(!button.1.intersects(other.1), "\(scenario) native '\(button.0)' and '\(other.0)' buttons do not overlap")
            }
        }
    }

    static func sample(_ panel: NSOpenPanel, bounds: NSRect, scenario: String, elapsed: Double) {
        let accessory = panel.accessoryView
        let labels = accessory.map(descendants)?.compactMap { $0 as? NSTextField } ?? []
        report("\(scenario) t=\(elapsed): panel=\(panel.frame), minSize=\(panel.minSize), contentMinSize=\(panel.contentMinSize), visibleFrame=\(bounds), accessory=\(String(describing: accessory?.frame)), labels=\(labels.map(\.frame))")
        require(panel.isVisible, "\(scenario) panel visible at \(elapsed)s")
        require(bounds.contains(panel.frame), "\(scenario) panel fits at \(elapsed)s")
        require(panel.frame.width >= panel.minSize.width && panel.frame.height >= panel.minSize.height,
                "\(scenario) panel respects native control minimum size at \(elapsed)s")
        require(!labels.isEmpty, "\(scenario) wrapping explanation exists")
        for label in labels {
            require(label.frame.width > 0 && label.frame.width <= panel.frame.width,
                    "\(scenario) explanation width is bounded")
            require(label.frame.height > 0, "\(scenario) explanation has visible height")
            let needed = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width,
                                                                 height: .greatestFiniteMagnitude)).height ?? 0
            require(label.bounds.height + 1 >= ceil(needed), "\(scenario) explanation is tall enough for wrapped text")
            if let accessory {
                let localFrame = accessory.convert(label.bounds, from: label)
                require(accessory.bounds.contains(localFrame), "\(scenario) explanation stays inside its local accessory")
            }
            if let content = panel.contentView, label.window === panel, label.isDescendant(of: content) {
                let frame = content.convert(label.bounds, from: label)
                report("\(scenario) explanation in content=\(frame), content=\(content.bounds), measuredHeight=\(needed)")
                require(content.bounds.contains(frame), "\(scenario) explanation remains inside visible panel content")
            } else if elapsed == 0.25 {
                report("NOTE: \(scenario) explanation is remotely hosted; measured wrapping height=\(needed), native screen coordinates unavailable")
            }
        }
        if let content = panel.contentView {
            let buttons = descendants(content).compactMap { $0 as? NSButton }.filter {
                !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 &&
                ($0.keyEquivalent == "\r" || $0.title == panel.prompt || ["Cancel", "Отменить", "Отмена"].contains($0.title) ||
                 $0.title.hasPrefix("New Folder") || $0.title.hasPrefix("Новая папка"))
            }
            for button in buttons {
                let frame = content.convert(button.bounds, from: button)
                report("\(scenario) button=\(button.title), frame=\(frame)")
                require(content.bounds.contains(frame), "\(scenario) visible '\(button.title)' button stays within panel")
            }
            if buttons.count >= 2 {
                verifyButtons(buttons.map { ($0.title, panel.convertToScreen($0.convert($0.bounds, to: nil))) }, in: panel, scenario: scenario)
                nativeButtonSamples += 1
            } else if elapsed == 1.5 {
                // AX uses top-left screen coordinates, while AppKit uses the
                // bottom-left origin. Restrict the check to the action row of
                // THIS panel, not another window's controls.
                let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
                let converted = remoteButtons.map { ($0.0, NSRect(x: $0.1.minX, y: screenTop - $0.1.maxY, width: $0.1.width, height: $0.1.height)) }
                if let primary = converted.first(where: { $0.0 == panel.prompt && panel.frame.contains($0.1) }) {
                    let row = converted.filter { abs($0.1.midY - primary.1.midY) <= 2 && panel.frame.contains($0.1) }
                    if row.count >= 2 {
                        verifyButtons(row, in: panel, scenario: scenario)
                        nativeButtonSamples += 1
                        report("BUTTON GEOMETRY: \(scenario) verified native action row \(row)")
                    } else { unavailableButtonSamples += 1 }
                } else { unavailableButtonSamples += 1 }
                if nativeButtonSamples == 0 {
                    report("UNVERIFIED: \(scenario) native action-button frames are remote and inaccessible")
                }
            }
        }
    }

    static func runPanel(recovery: Bool, backup: Bool = false, bounds: NSRect, small: Bool, home: URL, language: String) {
        visibleFrameOverride = small ? bounds : nil
        let scenario = "\(language)/\(backup ? "backup-sheet" : recovery ? "recovery" : "first-launch")/\(small ? "1024x600" : "actual-screen")"
        activeScenario = scenario
        report("STAGE: \(scenario) creating native panel")
        // AppKit hosts each panel in a remote service. Keep service failures
        // visible as test failures instead of passing an invalid ObjC result
        // into Swift KVO (which otherwise aborts with a null-pointer cast).
        let candidate: NSOpenPanel? = backup ? OEDataFolderSetup.makeDirectoryPanel(
            title: NSLocalizedString("Select Backup Folder", comment: "Folder backup picker title"),
            explanation: NSLocalizedString("Choose a folder to back up your save states, battery saves, and BIOS files. Pick a folder inside iCloud Drive to sync automatically across your Macs.", comment: "Folder backup picker explanation"))
            : OEDataFolderSetup.makeFolderPanel(isRecovery: recovery)
        guard let panel = candidate else {
            require(false, "\(scenario) AppKit could not create its remote open panel")
            activeScenario = ""
            visibleFrameOverride = nil
            return
        }
        report("STAGE: \(scenario) configuring native panel")
        panel.directoryURL = home
        panel.setFrame(NSRect(x: bounds.minX, y: bounds.minY, width: 4000, height: 2000), display: false)
        if language == "ru", !backup {
            require(panel.title == "Выберите папку данных OpenEmu", "Russian title loaded from bundle")
        }
        require(panel.prompt == nativePrompt, "AppKit supplies the native localized confirmation label")
        require(panel.canChooseDirectories && !panel.canChooseFiles, "Only folders are selectable")
        require(panel.canCreateDirectories == !recovery, "Recovery cannot create a replacement folder")
        report("\(scenario) title=\(panel.title ?? ""), prompt=\(panel.prompt ?? "")")
        remoteButtons = []
        let axTimer = Timer(timeInterval: 0.4, repeats: false) { _ in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = externalButtons()
                RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) {
                    MainActor.assumeIsolated {
                        guard activeScenario == scenario else { return }
                        remoteButtons = result.0
                        report("EXTERNAL AX: \(scenario) \(result.1), buttons=\(result.0)")
                    }
                }
            }
        }

        var timers: [Timer] = [axTimer]
        for elapsed in [0.25, 0.75, 1.5, 2.75] {
            let timer = Timer(timeInterval: elapsed, repeats: false) { _ in
                MainActor.assumeIsolated {
                    sample(panel, bounds: bounds, scenario: scenario, elapsed: elapsed)
                    if elapsed == 0.75 { capture(panel, scenario: scenario) }
                    if elapsed == 2.75 { panel.cancel(nil) }
                }
            }
            timers.append(timer)
        }
        // Simulate restored/native geometry being applied after the key-window
        // callback, which an initial-only fitting pass cannot repair.
        let lateResize = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                panel.setFrame(NSRect(x: bounds.minX, y: bounds.minY, width: 1800, height: 1000), display: false)
            }
        }
        timers.append(lateResize)
        if !backup {
            // Native restoration can move a correctly sized modal panel after
            // its resize notification has already been handled. Move only its
            // origin, on the same screen, so resize/screen observers cannot
            // accidentally stand in for the missing move observation.
            let lateMove = Timer(timeInterval: 2.35, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let size = panel.frame.size
                    panel.setFrameOrigin(NSPoint(x: bounds.minX - 160, y: panel.frame.minY))
                    require(panel.frame.size == size, "\(scenario) late move preserves panel size")
                    require(!bounds.contains(panel.frame), "\(scenario) late move injects an off-screen origin")
                    report("INJECTED ORIGIN-ONLY MOVE: \(scenario) frame=\(panel.frame)")
                }
            }
            timers.append(lateMove)
        }
        timers.forEach { RunLoop.main.add($0, forMode: backup ? .default : .modalPanel) }
        let result: NSApplication.ModalResponse
        if backup {
            let parent = NSWindow(contentRect: NSRect(x: bounds.midX - 400, y: bounds.midY - 200, width: 800, height: 400),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            parent.makeKeyAndOrderFront(nil)
            var sheetResponse: NSApplication.ModalResponse?
            report("STAGE: \(scenario) presenting native sheet")
            OEDataFolderSetup.beginFolderPanel(panel, for: parent) { sheetResponse = $0 }
            let deadline = Date().addingTimeInterval(10)
            while sheetResponse == nil, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            result = sheetResponse ?? .abort
            if sheetResponse == nil { panel.cancel(nil) }
            parent.close()
        } else {
            report("STAGE: \(scenario) entering native modal loop")
            result = OEDataFolderSetup.runFolderPanel(panel)
        }
        report("STAGE: \(scenario) native panel finished (\(result.rawValue))")
        timers.forEach { $0.invalidate() }
        activeScenario = ""
        require(result == .cancel, "\(scenario) always cancels without selecting a folder")
        visibleFrameOverride = nil
    }

    @MainActor private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
        let fixedHome: String
        let language: String

        init(fixedHome: String, language: String) {
            self.fixedHome = fixedHome
            self.language = language
        }

        func applicationWillFinishLaunching(_ notification: Notification) {
            report("STAGE: AppKit will finish launching")
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            report("STAGE: AppKit finished launching; scheduling panel tests")
            // Exercise the remote file-panel service under the normal AppKit
            // launch/event-loop lifecycle. Calling finishLaunching() manually
            // does not start that loop. Begin after the launch callback returns.
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    runScenarios(fixedHome: self.fixedHome, language: self.language)
                }
            }
        }
    }

    static func main() {
        report("STAGE: panel fixture started (\(ProcessInfo.processInfo.operatingSystemVersionString))")
        guard let fixedHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              fixedHome.hasPrefix("/private/tmp/openemu-data-folder-panel.") || fixedHome.hasPrefix("/tmp/openemu-data-folder-panel.") else {
            report("FAIL: an isolated test home is required")
            exit(EXIT_FAILURE)
        }
        let language = ProcessInfo.processInfo.environment["OE_PANEL_TEST_LANGUAGE"] ?? "ru"
        report("STAGE: \(language) creating NSApplication")
        let application = NSApplication.shared
        report("STAGE: \(language) setting accessory activation policy")
        application.setActivationPolicy(.accessory)
        let delegate = ApplicationDelegate(fixedHome: fixedHome, language: language)
        application.delegate = delegate
        report("STAGE: \(language) starting NSApplication event loop")
        withExtendedLifetime(delegate) { application.run() }
        report("FAIL: AppKit event loop stopped before panel tests completed")
        exit(EXIT_FAILURE)
    }

    static func runScenarios(fixedHome: String, language: String) {
        require(NSApplication.shared.isRunning, "Native panel tests run inside the NSApplication event loop")
        report("STAGE: \(language) creating reference native panel")
        // Read the uncustomized label once, not by creating an additional
        // unused remote panel during every scenario. Drain this reference and
        // each completed scenario just as NSApplication's event loop would.
        nativePrompt = autoreleasepool {
            let reference: NSOpenPanel? = NSOpenPanel()
            return reference?.prompt ?? ""
        }
        guard !nativePrompt.isEmpty else {
            report("FAIL: AppKit could not create the reference open panel")
            exit(EXIT_FAILURE)
        }
        report("STAGE: \(language) checking the logged-in display")
        guard let screen = NSScreen.main,
              let original = class_getInstanceMethod(NSScreen.self, #selector(getter: NSScreen.visibleFrame)),
              let replacement = class_getInstanceMethod(NSScreen.self, #selector(NSScreen.oePanelTestVisibleFrame)) else {
            report("FAIL: a logged-in macOS display is required")
            exit(EXIT_FAILURE)
        }
        let actualBounds = screen.visibleFrame
        method_exchangeImplementations(original, replacement)
        defer { method_exchangeImplementations(original, replacement) }
        let smallBounds = NSRect(x: actualBounds.minX, y: actualBounds.minY, width: 1024, height: 600)
        let home = URL(fileURLWithPath: fixedHome, isDirectory: true)
        for small in [false, true] {
            for recovery in [false, true] {
                autoreleasepool {
                    runPanel(recovery: recovery, bounds: small ? smallBounds : actualBounds,
                             small: small, home: home, language: language)
                }
            }
            autoreleasepool {
                runPanel(recovery: false, backup: true, bounds: small ? smallBounds : actualBounds,
                         small: small, home: home, language: language)
            }
        }
        if ProcessInfo.processInfo.environment["OE_PANEL_TEST_REQUIRE_BUTTON_GEOMETRY"] == "YES" {
            require(unavailableButtonSamples == 0, "Native button geometry must be available for every scenario in strict mode")
        }
        report(failures.isEmpty
               ? "PASS: \(language) native panel lifetime, late restored sizing, recovery and smaller screen; no folder selected"
               : "FAIL: \(language) \(failures.count) panel assertions failed")
        report("COVERAGE: \(nativeButtonSamples) native-button geometry samples; \(unavailableButtonSamples) panels without native-button frames")
        exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
