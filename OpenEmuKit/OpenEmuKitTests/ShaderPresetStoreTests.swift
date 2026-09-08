// Copyright (c) 2021, OpenEmu Team
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
import Nimble
import OpenEmuBase
@testable import OpenEmuKit

class UserDefaultsPresetStorageTests: XCTestCase {
    
    private var defaults: UserDefaults!
    private var store: UserDefaultsPresetStorage!
    
    private var path: String!
    
    override func setUp() {
        path = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("OpenEmuKitTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString).absoluteString
        
        defaults = UserDefaults(suiteName: path)
        defaults.removePersistentDomain(forName: path)
        
        store = UserDefaultsPresetStorage(store: defaults)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    func testSaveSearch() throws {
        try store.save(ShaderPresetData(name: "id1", shader: "CRT", parameters: [:]))
        try store.save(ShaderPresetData(name: "id2", shader: "CRT", parameters: [:]))
        try store.save(ShaderPresetData(name: "id3", shader: "MAME", parameters: [:]))
        try store.save(ShaderPresetData(name: "id4", shader: "Pixellate", parameters: [:]))
    
        do {
            let presets = store.findPresets(byShader: "CRT")
            let exp = [
                "id1",
                "id2",
            ]
            expect(presets.map(\.id)).to(contain(exp))
        }
        
        // Test removing a preset
        do {
            let preset = store.findPreset(byID: "id1")!
            store.remove(preset)
            let presets = store.findPresets(byShader: "CRT")
            let exp = [ "id2" ]
            expect(presets.map(\.id)).to(contain(exp))
        }
    }
    
    func testFailsForModifiedShader() {
        let store = store!
        expect {
            try store.save(ShaderPresetData(name: "foo", shader: "CRT", parameters: [:], id: "id1"))
            try store.save(ShaderPresetData(name: "foo", shader: "MAME", parameters: [:], id: "id1"))
        }
        .to(throwError(ShaderPresetStorageError.shaderModified))
    }

    func testPresetIndexReloadsFromInjectedPreferencesStore() throws {
        // Keep standalone UserDefaults clients working through the same
        // interface used by OpenEmu's file-backed settings.
        let preferences: OEPreferencesStore = defaults
        let first = UserDefaultsPresetStorage(store: preferences)
        try first.save(ShaderPresetData(name: "Custom CRT", shader: "CRT", parameters: ["brightness": 0.5], id: "custom"))

        let reloaded = UserDefaultsPresetStorage(store: preferences)
        XCTAssertEqual(reloaded.findPresets(byShader: "CRT").map(\.id), ["custom"])
        XCTAssertEqual(reloaded.findPreset(byID: "custom")?.parameters, ["brightness": 0.5])
        XCTAssertTrue(reloaded.exists(byID: UserDefaultsPresetStorage.makeKey("custom")))
        reloaded.remove(try XCTUnwrap(reloaded.findPreset(byID: "custom")))
        XCTAssertTrue(reloaded.findPresets(byShader: "CRT").isEmpty)
        XCTAssertNil(preferences.string(forKey: UserDefaultsPresetStorage.makeKey("custom")))
    }

    func testSystemShaderSettingsUseInjectedPreferencesStore() {
        let preferences: OEPreferencesStore = defaults
        let shaders = OEShaderStore(store: preferences, bundle: Bundle(for: Self.self))
        let systems = OESystemShaderStore(store: preferences, shaders: shaders)
        let shader = OEShaderModel(name: "CRT")
        let identifier = "openemu.system.nes"

        shaders.defaultShaderName = "CRT"
        XCTAssertEqual(preferences.string(forKey: "videoShader"), "CRT")
        systems.setShader(shader, forSystem: identifier)
        XCTAssertEqual(preferences.string(forKey: "videoShader.\(identifier)"), "CRT")
        systems.write(parameters: "brightness=0.5", forShader: "CRT", identifier: identifier)
        let model = systems.shader(withShader: shader, forSystem: identifier)
        XCTAssertEqual(model.parameters, ["brightness": 0.5])
        systems.remove(parametersForShader: "CRT", identifier: identifier)
        XCTAssertNil(model.parameters)
        systems.resetShader(forSystem: identifier)
        XCTAssertNil(preferences.string(forKey: "videoShader.\(identifier)"))

        let presets = ShaderPresetStore(store: store, shaders: shaders)
        let systemPresets = SystemShaderPresetStore(store: preferences, presets: presets, shaders: shaders)
        let preset = ShaderPreset(name: "Custom CRT", shader: shader, parameters: [:], id: "custom")
        systemPresets.setPreset(preset, forSystem: identifier)
        XCTAssertEqual(preferences.string(forKey: "videoShader.\(identifier).preset"), "custom")
        systemPresets.resetPresetForSystem(identifier)
        XCTAssertNil(preferences.string(forKey: "videoShader.\(identifier).preset"))
    }
}
