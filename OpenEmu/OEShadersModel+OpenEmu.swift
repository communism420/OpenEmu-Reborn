// Copyright (c) 2019, OpenEmu Team
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

import AppKit
import OpenEmuKit
import OpenEmuBase

/// Menu labels may be translated, but shader lookup and preferences always use
/// the original name carried by each item's representedObject.
enum OEShaderMenu {
    static let noShaderName = "No Shader"

    static func displayName(for name: String) -> String {
        name == noShaderName ? NSLocalizedString("No Shader", comment: "Shader option: display the game without a shader") : name
    }

    @MainActor
    static func makeMenu(store: OEShaderStore, selectedShaderName: String, action: Selector?) -> NSMenu {
        let menu = NSMenu()
        func add(_ name: String) {
            let item = NSMenuItem(title: displayName(for: name), action: action, keyEquivalent: "")
            item.representedObject = name
            item.state = name == selectedShaderName ? .on : .off
            menu.addItem(item)
        }

        if store.shader(withName: noShaderName) != nil {
            add(noShaderName)
            menu.addItem(.separator())
        }
        store.sortedSystemShaderNames.filter { $0 != noShaderName }.forEach(add)
        let customNames = store.sortedCustomShaderNames.filter { $0 != noShaderName }
        if !customNames.isEmpty {
            if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
                menu.addItem(.separator())
            }
            customNames.forEach(add)
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }

    @MainActor
    @discardableResult
    static func selectShader(named name: String, in picker: NSPopUpButton) -> Bool {
        guard let item = picker.itemArray.first(where: { $0.representedObject as? String == name }) else { return false }
        picker.select(item)
        for candidate in picker.itemArray where !candidate.isSeparatorItem {
            candidate.state = candidate === item ? .on : .off
        }
        return true
    }
}

extension OEShaderStore {
    @objc
    public static var shared: OEShaderStore = {
        .init(store: OEPreferences.shared, bundle: .main)
    }()
}

extension OESystemShaderStore {
    @objc
    public static var shared: OESystemShaderStore = {
        .init(store: OEPreferences.shared, shaders: .shared)
    }()
}

extension UserDefaultsPresetStorage {
    public static var shared: UserDefaultsPresetStorage = {
        .init(store: OEPreferences.shared)
    }()
}

extension ShaderPresetStore {
    public static var shared: ShaderPresetStore = {
        .init(store: UserDefaultsPresetStorage.shared, shaders: .shared)
    }()
}

extension SystemShaderPresetStore {
    public static var shared: SystemShaderPresetStore = {
        .init(store: OEPreferences.shared, presets: .shared, shaders: .shared)
    }()
}
