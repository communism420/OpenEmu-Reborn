// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-2-Clause

import AppKit
import AudioToolbox
import OpenEmuBase
import OpenEmuSystem
import OpenEmuKit

// Only game/system metadata and the remote renderer are replaced. The tests
// compile the production ShaderControl/menu code and use real preference,
// shader and preset stores from the supplied, already built application.
public final class OESystemPlugin: NSObject {
    public let systemIdentifier = "org.openemu.tests.no-shader-system"
    public let systemName = "Fixture System"
}

final class OEGameDocument: NSObject {
    let systemPlugin = OESystemPlugin()
    let gameCoreHelper: OEGameCoreHelper?

    init(helper: OEGameCoreHelper) { gameCoreHelper = helper }
}

final class RecordingShaderHelper: NSObject, OEGameCoreHelper {
    var shaderURLs: [URL] = []
    var shaderParameters: [[String: NSNumber]?] = []
    var nextError: Error?

    func setShaderURL(_ url: URL, parameters: [String: NSNumber]?, completionHandler block: @escaping (Error?) -> Void) {
        shaderURLs.append(url)
        shaderParameters.append(parameters)
        let error = nextError
        nextError = nil
        block(error)
    }

    // Any unrelated call, including resetting gamma/saturation, is a failure.
    private func unexpected() -> Never { fatalError("Unexpected non-shader helper call") }
    func setShaderParameterValue(_ value: CGFloat, forKey key: String) { unexpected() }
    func setVolume(_ value: Float) { unexpected() }
    func setPauseEmulation(_ pauseEmulation: Bool) { unexpected() }
    func canPauseRetroAchievementsHardcore(completionHandler block: @escaping (Bool, UInt32) -> Void) { unexpected() }
    func setEffectsMode(_ mode: OEGameCoreEffectsMode) { unexpected() }
    func setAudioOutputDeviceID(_ deviceID: AudioDeviceID) { unexpected() }
    func setOutputBounds(_ rect: NSRect) { unexpected() }
    func setBackingScaleFactor(_ newBackingScaleFactor: CGFloat) { unexpected() }
    func setAdaptiveSyncEnabled(_ enabled: Bool) { unexpected() }
    func setGlobalShaderParameters(gamma: CGFloat, saturation: CGFloat) { unexpected() }
    func setupEmulation(completionHandler handler: @escaping (OEIntSize, OEIntSize) -> Void) { unexpected() }
    func startEmulation(completionHandler handler: @escaping () -> Void) { unexpected() }
    func resetEmulation(completionHandler handler: @escaping () -> Void) { unexpected() }
    func stopEmulation(completionHandler handler: @escaping () -> Void) { unexpected() }
    func saveStateToFile(at fileURL: URL, completionHandler block: @escaping (Bool, Error?) -> Void) { unexpected() }
    func loadStateFromFile(at fileURL: URL, completionHandler block: @escaping (Bool, Error?) -> Void) { unexpected() }
    func setCheat(_ cheatCode: String, withType type: String, enabled: Bool) { unexpected() }
    func readableMemoryRegions(completionHandler block: @escaping ([[String: Any]]) -> Void) { unexpected() }
    func setDisc(_ discNumber: UInt) { unexpected() }
    func changeDisplay(withMode displayMode: String) { unexpected() }
    func insertFile(at url: URL, completionHandler block: @escaping (Bool, Error?) -> Void) { unexpected() }
    func handleMouseEvent(_ event: OEEvent) { unexpected() }
    func setHandleEvents(_ handleEvents: Bool) { unexpected() }
    func setHandleKeyboardEvents(_ handleKeyboardEvents: Bool) { unexpected() }
    func systemBindingsDidSetEvent(_ event: OEHIDEvent, forBinding bindingDescription: OEBindingDescription, playerNumber: UInt) { unexpected() }
    func systemBindingsDidUnsetEvent(_ event: OEHIDEvent, forBinding bindingDescription: OEBindingDescription, playerNumber: UInt) { unexpected() }
    func captureOutputImage(completionHandler block: @escaping (NSBitmapImageRep) -> Void) { unexpected() }
    func captureSourceImage(completionHandler block: @escaping (NSBitmapImageRep) -> Void) { unexpected() }
    func setRetroAchievementsToken(_ token: String?, username: String?) { unexpected() }
    func setHardcoreEnabled(_ enabled: Bool) { unexpected() }
}

@main
struct NoShaderSelectionSmokeTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    @MainActor
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    static func run() throws {
        let arguments = ProcessInfo.processInfo.arguments
        try require(arguments.count >= 3, "Expected an isolated data directory and mode")
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        let canonicalPath = root.resolvingSymlinksInPath().path
        try require(canonicalPath.hasPrefix("/private/tmp/openemu-no-shader-selection.") ||
                    canonicalPath.hasPrefix("/tmp/openemu-no-shader-selection."), "Refusing a non-test data directory")
        try OEStoragePaths.configure(dataRootURL: root)
        try OEPreferences.configure(url: root.appendingPathComponent("Settings.plist"), readOnly: false)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let store = OEShaderStore.shared
        guard let off = store.shader(withName: "No Shader"), let on = store.shader(withName: "Pixellate") else {
            throw Failure(description: "The supplied app must bundle No Shader and Pixellate")
        }
        try require(off.name == "No Shader", "Stable shader name")
        try require(off.defaultParameters.isEmpty && off.readGroups().flatMap(\.parameters).isEmpty, "No Shader has no parameters")
        try require(OEShaderMenu.displayName(for: off.name) == "Без шейдера", "Russian label is localized")
        try require(OEShaderMenu.displayName(for: on.name) == "Pixellate", "Other shader names are unchanged")
        let menu = OEShaderMenu.makeMenu(store: store, selectedShaderName: off.name, action: nil)
        try require(menu.items.first?.title == "Без шейдера", "No Shader is pinned first")
        try require(menu.items.first?.representedObject as? String == "No Shader", "Localized item retains its English identifier")
        try require(menu.items.first?.state == .on, "Selected shader checkmark")
        try require(menu.items.filter { $0.representedObject as? String == "No Shader" }.count == 1, "No duplicate off choices")

        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.menu = menu
        for shader in [on, off, on, off] {
            try require(OEShaderMenu.selectShader(named: shader.name, in: picker), "Picker can switch both ways")
            try require(picker.selectedItem?.representedObject as? String == shader.name, "Picker selects by stable identifier")
            try require(picker.itemArray.filter { $0.state == .on }.count == 1, "Exactly one checked picker item")
        }

        let helper = RecordingShaderHelper()
        let document = OEGameDocument(helper: helper)
        let control = ShaderControl(document: document)
        let identifier = document.systemPlugin.systemIdentifier
        if arguments[2] == "restart" {
            try require(store.defaultShaderName == off.name, "Global selection persisted across process restart")
            try require(control.preset.shader.name == off.name, "System selection persisted across process restart")
            try require(OEPreferences.shared.string(forKey: "videoShader") == "No Shader", "No translated name stored")
            try require(OEPreferences.shared.double(forKey: "OEImageGamma") == 1.25, "Gamma survives restart")
            try require(OEPreferences.shared.double(forKey: "OEImageSaturation") == 1.5, "Saturation survives restart")
            print("PASS: localized menus and persisted No Shader after restart")
            return
        }
        try require(arguments[2] == "exercise", "Unknown test mode")
        try require(control.preset.shader.name == on.name, "Existing Pixellate default is unchanged")
        OEPreferences.shared.set(1.25, forKey: "OEImageGamma")
        OEPreferences.shared.set(1.5, forKey: "OEImageSaturation")

        control.changeShader(off)
        try require(helper.shaderURLs.last == off.url, "Renderer receives the bundled zero-pass preset URL")
        try require(helper.shaderParameters.last.flatMap { $0 }?.isEmpty != false, "No Shader sends no adjustable parameters")
        try require(control.preset.shader.name == off.name, "Control switches to No Shader")
        try require(OESystemShaderStore.shared.shader(forSystem: identifier).shader.name == off.name, "System stores No Shader")
        let recreated = ShaderControl(document: document)
        try require(recreated.preset.shader.name == off.name, "New controller restores system selection")
        control.changeShader(on)
        try require(helper.shaderURLs.last == on.url && control.preset.shader.name == on.name, "Renderer and controller switch back")

        let namedPreset = ShaderPreset(name: "Fixture preset", shader: on, parameters: [:], id: "no-shader-fixture-preset")
        try control.savePreset(namedPreset)
        control.changePreset(namedPreset)
        try require(SystemShaderPresetStore.shared.findPresetForSystem(identifier)?.id == namedPreset.id, "Named preset assignment exists")
        control.changeShader(off)
        try require(SystemShaderPresetStore.shared.findPresetForSystem(identifier) == nil, "Switching off clears the overriding named-preset assignment")
        try require(ShaderPresetStore.shared.findPreset(byID: namedPreset.id) != nil, "Saved named preset is not deleted")

        helper.nextError = CocoaError(.fileReadUnknown)
        control.changeShader(on)
        try require(control.preset.shader.name == off.name, "Failed renderer switch keeps previous selection")
        try require(OESystemShaderStore.shared.shader(forSystem: identifier).shader.name == off.name, "Failed renderer switch keeps stored selection")
        try require(OEPreferences.shared.double(forKey: "OEImageGamma") == 1.25, "Switching shaders does not reset gamma")
        try require(OEPreferences.shared.double(forKey: "OEImageSaturation") == 1.5, "Switching shaders does not reset saturation")
        store.defaultShaderName = off.name
        try require(store.defaultShader.name == off.name, "Global default accepts No Shader")
        try require(OEPreferences.shared.synchronize(), "Test settings persisted")
        print("PASS: real ShaderControl off/on switching, renderer URL, error rollback, system/preset settings, menu identity/checkmarks; gamma/saturation unchanged")
    }
}
