// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

import AppKit

/// Collects a choice only. Removal is performed separately, after confirmation
/// and after the app has stopped using its library and emulator files.
@MainActor
final class OEDataRemovalDialog: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        var onCancel: (() -> Void)?

        override func cancelOperation(_ sender: Any?) {
            onCancel?()
        }
    }

    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 600),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
    private var checkboxes: [OEDataRemovalCategory: NSButton] = [:]
    private var selected: Set<OEDataRemovalCategory>
    private let continueButton = NSButton()

    static func chooseCategories(in root: URL) -> Set<OEDataRemovalCategory>? {
        let dialog = OEDataRemovalDialog(root: root, categories: [.preferences, .controls, .accounts], confirming: false)
        return dialog.run() == .OK ? dialog.selected : nil
    }

    static func confirm(categories: Set<OEDataRemovalCategory>, in root: URL) -> Bool {
        guard !categories.isEmpty else { return false }
        let dialog = OEDataRemovalDialog(root: root, categories: categories, confirming: true)
        return withExtendedLifetime(dialog) { dialog.run() == .OK }
    }

    private init(root: URL, categories: Set<OEDataRemovalCategory>, confirming: Bool) {
        selected = categories
        super.init()
        panel.title = NSLocalizedString("Remove OpenEmu Data", comment: "Data removal window")
        panel.identifier = NSUserInterfaceItemIdentifier(confirming ? "OEDataRemovalConfirmation" : "OEDataRemovalChooser")
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.finish(.cancel) }
        panel.contentMinSize = NSSize(width: 440, height: 360)

        guard let content = panel.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])

        let heading = label(confirming
                            ? NSLocalizedString("Move the selected data to Trash?", comment: "Confirm data removal heading")
                            : NSLocalizedString("Choose what to remove", comment: "Data removal heading"))
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        add(heading, to: stack)

        let scope = label(NSLocalizedString("Only data inside this folder is affected. External files and OpenEmu.app, including its bundled cores, are kept.", comment: "Data removal boundary"))
        add(scope, to: stack)

        // Keep arbitrarily long paths from making the window taller or wider.
        // The complete path is selectable and appears in the field's tooltip.
        let path = NSTextField(labelWithString: root.path)
        path.isSelectable = true
        path.lineBreakMode = .byTruncatingMiddle
        path.maximumNumberOfLines = 1
        path.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        path.textColor = .secondaryLabelColor
        path.toolTip = root.path
        path.setAccessibilityLabel(NSLocalizedString("Data folder", comment: "Data removal path accessibility label"))
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        add(path, to: stack)

        if !confirming {
            let selectAll = button(NSLocalizedString("Select All", comment: "Select all data categories"), action: #selector(selectAllCategories))
            selectAll.identifier = NSUserInterfaceItemIdentifier("OEDataRemovalSelectAll")
            let deselectAll = button(NSLocalizedString("Deselect All", comment: "Deselect all data categories"), action: #selector(deselectAllCategories))
            deselectAll.identifier = NSUserInterfaceItemIdentifier("OEDataRemovalDeselectAll")
            let selectionButtons = NSStackView(views: [selectAll, deselectAll])
            selectionButtons.spacing = 8
            stack.addArrangedSubview(selectionButtons)
        }

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        for category in OEDataRemovalCategory.allCases where !confirming || categories.contains(category) {
            let row = makeRow(category, confirming: confirming)
            add(row, to: rows)
        }

        let document = DocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.documentView = document
        scroll.identifier = NSUserInterfaceItemIdentifier("OEDataRemovalCategories")
        add(scroll, to: stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 70)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let outcome: String
        if confirming {
            outcome = categories.contains(.preferences)
                ? NSLocalizedString("OpenEmu will quit, then remove the selected data, including Settings.plist and its lock file. Its next launch will repeat first-time setup. Removed files can be recovered from Trash. Hidden folder markers and an empty sign-in store may remain.", comment: "Confirm removal with settings reset")
                : NSLocalizedString("OpenEmu will quit, then remove the selected data. Your app settings and chosen data folder will be kept. Removed files can be recovered from Trash. Hidden folder markers and an empty sign-in store may remain.", comment: "Confirm removal without settings reset")
        } else {
            outcome = NSLocalizedString("Nothing is removed until you confirm on the next screen. Select OpenEmu Settings to repeat first-time setup on the next launch.", comment: "Data removal selection safety explanation")
        }
        let outcomeLabel = label(outcome)
        outcomeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        add(outcomeLabel, to: stack)

        let cancel = button(NSLocalizedString("Cancel", comment: "Cancel data removal"), action: #selector(cancel))
        cancel.identifier = NSUserInterfaceItemIdentifier("OEDataRemovalCancel")
        // Return never authorizes removal. Escape is handled by Panel above.
        cancel.keyEquivalent = "\r"
        continueButton.title = confirming
            ? NSLocalizedString("Move to Trash and Quit", comment: "Confirm selected data removal")
            : NSLocalizedString("Continue…", comment: "Review selected data removal")
        continueButton.bezelStyle = .rounded
        continueButton.target = self
        continueButton.action = #selector(proceed)
        continueButton.identifier = NSUserInterfaceItemIdentifier("OEDataRemovalContinue")
        continueButton.isEnabled = !selected.isEmpty
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, continueButton])
        buttons.spacing = 8
        add(buttons, to: stack)
        panel.defaultButtonCell = cancel.cell as? NSButtonCell
    }

    private func makeRow(_ category: OEDataRemovalCategory, confirming: Bool) -> NSView {
        let row = NSView()
        let title: NSView
        if confirming {
            let name = label(Self.title(for: category))
            name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            title = name
        } else {
            let checkbox = NSButton(checkboxWithTitle: Self.title(for: category), target: self, action: #selector(selectionChanged))
            checkbox.identifier = NSUserInterfaceItemIdentifier("OEDataRemovalCategory.\(category.rawValue)")
            checkbox.state = selected.contains(category) ? .on : .off
            checkbox.setAccessibilityHelp(Self.explanation(for: category))
            checkboxes[category] = checkbox
            title = checkbox
        }
        let explanation = label(Self.explanation(for: category))
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        explanation.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(title)
        row.addSubview(explanation)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            title.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            explanation.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: confirming ? 0 : 20),
            explanation.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            explanation.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            explanation.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8)
        ])
        return row
    }

    private func run() -> NSApplication.ModalResponse {
        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitToScreen() }
        }
        defer { NotificationCenter.default.removeObserver(screenObserver) }
        fitToScreen(center: true)
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return response
    }

    private func fitToScreen(center: Bool = false) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        var frame = panel.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = center ? visible.midX - frame.width / 2 : min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = center ? visible.midY - frame.height / 2 : min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        fitToScreen()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.cancel)
        return false
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        NSApp.stopModal(withCode: response)
    }

    @objc private func cancel() { finish(.cancel) }
    @objc private func proceed() {
        guard !selected.isEmpty else { return }
        finish(.OK)
    }

    @objc private func selectAllCategories() {
        checkboxes.values.forEach { $0.state = .on }
        selectionChanged()
    }

    @objc private func deselectAllCategories() {
        checkboxes.values.forEach { $0.state = .off }
        selectionChanged()
    }

    @objc private func selectionChanged() {
        selected = Set(checkboxes.compactMap { $0.value.state == .on ? $0.key : nil })
        continueButton.isEnabled = !selected.isEmpty
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        return label
    }

    private func add(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private static func title(for category: OEDataRemovalCategory) -> String {
        switch category {
        case .preferences: NSLocalizedString("OpenEmu Settings", comment: "Removal category")
        case .controls: NSLocalizedString("Controller Mappings", comment: "Removal category")
        case .accounts: NSLocalizedString("Account Sign-ins", comment: "Removal category")
        case .library: NSLocalizedString("Game Library and Games", comment: "Removal category")
        case .emulationData: NSLocalizedString("Saves and Console Data", comment: "Removal category")
        case .bios: NSLocalizedString("BIOS and Firmware", comment: "Removal category")
        case .screenshots: NSLocalizedString("Screenshots", comment: "Removal category")
        case .plugins: NSLocalizedString("Installed Cores and System Plugins", comment: "Removal category")
        case .shaders: NSLocalizedString("Custom Shader Files", comment: "Removal category")
        case .caches: NSLocalizedString("Caches and Temporary Files", comment: "Removal category")
        case .other: NSLocalizedString("Other Files in This Folder", comment: "Removal category")
        }
    }

    private static func explanation(for category: OEDataRemovalCategory) -> String {
        switch category {
        case .preferences: NSLocalizedString("App preferences, window settings and first-time setup.", comment: "Removal category detail")
        case .controls: NSLocalizedString("Saved keyboard and game controller mappings.", comment: "Removal category detail")
        case .accounts: NSLocalizedString("Saved account credentials and sign-in information in this folder.", comment: "Removal category detail")
        case .library: NSLocalizedString("Game files, the library database, artwork and cheats inside this folder. External games are kept. Kept saves and screenshots may lose their library records.", comment: "Removal category detail")
        case .emulationData: NSLocalizedString("Save states, battery saves, memory cards and emulator support folders, including installed console content and configuration.", comment: "Removal category detail")
        case .bios: NSLocalizedString("The BIOS folder. Firmware inside emulator support folders is included under Saves and Console Data.", comment: "Removal category detail")
        case .screenshots: NSLocalizedString("OpenEmu screenshots and their custom in-folder location. Core-owned screenshots are included under Saves and Console Data.", comment: "Removal category detail")
        case .plugins: NSLocalizedString("The installed Cores and Systems folders. Cores bundled inside OpenEmu.app are kept.", comment: "Removal category detail")
        case .shaders: NSLocalizedString("Files in the Shaders folder. Presets saved in app preferences are included under OpenEmu Settings.", comment: "Removal category detail")
        case .caches: NSLocalizedString("OpenEmu caches and temporary files stored in this folder.", comment: "Removal category detail")
        case .other: NSLocalizedString("All remaining files, including files you added manually. Technical folder identity, lock and pending removal records are kept.", comment: "Removal category detail")
        }
    }
}
