// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-2-Clause

import AppKit
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

    static func report(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message); report("FAIL: " + message) }
    }

    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    static func sample(_ panel: NSOpenPanel, bounds: NSRect, scenario: String, elapsed: Double) {
        let accessory = panel.accessoryView
        let labels = accessory.map(descendants)?.compactMap { $0 as? NSTextField } ?? []
        report("\(scenario) t=\(elapsed): panel=\(panel.frame), visibleFrame=\(bounds), accessory=\(String(describing: accessory?.frame)), labels=\(labels.map(\.frame))")
        require(panel.isVisible, "\(scenario) panel visible at \(elapsed)s")
        require(bounds.contains(panel.frame), "\(scenario) panel fits at \(elapsed)s")
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
                ($0.title == panel.prompt || ["Cancel", "Отменить", "Отмена"].contains($0.title) ||
                 $0.title.hasPrefix("New Folder") || $0.title.hasPrefix("Новая папка"))
            }
            for button in buttons {
                let frame = content.convert(button.bounds, from: button)
                report("\(scenario) button=\(button.title), frame=\(frame)")
                require(content.bounds.contains(frame), "\(scenario) visible '\(button.title)' button stays within panel")
            }
            if buttons.isEmpty, elapsed == 0.25 {
                report("NOTE: \(scenario) native buttons are remotely hosted; button-frame checks unavailable")
            }
        }
    }

    static func runPanel(recovery: Bool, bounds: NSRect, small: Bool, home: URL, language: String) {
        visibleFrameOverride = small ? bounds : nil
        let scenario = "\(language)/\(recovery ? "recovery" : "first-launch")/\(small ? "1024x600" : "actual-screen")"
        let panel = OEDataFolderSetup.makeFolderPanel(isRecovery: recovery)
        panel.directoryURL = home
        panel.setFrame(NSRect(x: bounds.minX, y: bounds.minY, width: 4000, height: 2000), display: false)
        if language == "ru" {
            require(panel.title == "Выберите папку данных OpenEmu", "Russian title loaded from bundle")
            require(panel.prompt == "Использовать эту папку", "Russian confirmation label loaded from bundle")
        }
        require(panel.canChooseDirectories && !panel.canChooseFiles, "Only folders are selectable")
        require(panel.canCreateDirectories == !recovery, "Recovery cannot create a replacement folder")
        report("\(scenario) title=\(panel.title ?? ""), prompt=\(panel.prompt ?? "")")

        var timers: [Timer] = []
        for elapsed in [0.25, 0.75, 1.5, 2.75] {
            let timer = Timer(timeInterval: elapsed, repeats: false) { _ in
                MainActor.assumeIsolated {
                    sample(panel, bounds: bounds, scenario: scenario, elapsed: elapsed)
                    if elapsed == 2.75 { panel.cancel(nil) }
                }
            }
            timers.append(timer)
        }
        // Simulate restored/native geometry being applied after the key-window
        // callback, which an initial-only fitting pass cannot repair.
        let lateResize = Timer(timeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated {
                panel.setFrame(NSRect(x: bounds.minX, y: bounds.minY, width: 1800, height: 1000), display: false)
            }
        }
        timers.append(lateResize)
        timers.forEach { RunLoop.main.add($0, forMode: .modalPanel) }
        let result = OEDataFolderSetup.runFolderPanel(panel)
        timers.forEach { $0.invalidate() }
        require(result == .cancel, "\(scenario) always cancels without selecting a folder")
        visibleFrameOverride = nil
    }

    static func main() {
        guard let fixedHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              fixedHome.hasPrefix("/private/tmp/openemu-data-folder-panel.") || fixedHome.hasPrefix("/tmp/openemu-data-folder-panel.") else {
            report("FAIL: an isolated test home is required")
            exit(EXIT_FAILURE)
        }
        let language = ProcessInfo.processInfo.environment["OE_PANEL_TEST_LANGUAGE"] ?? "ru"
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
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
                runPanel(recovery: recovery, bounds: small ? smallBounds : actualBounds,
                         small: small, home: home, language: language)
            }
        }
        report(failures.isEmpty
               ? "PASS: \(language) native panel lifetime, late restored sizing, recovery and smaller screen; no folder selected"
               : "FAIL: \(language) \(failures.count) panel assertions failed")
        exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
