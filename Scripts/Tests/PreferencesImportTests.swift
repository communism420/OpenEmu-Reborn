// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
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

import Foundation

func checkPreferencesAPI(root: URL) throws {
    try OEPreferences.configure(url: root, readOnly: false)
    let store: any OEPreferencesStore = OEPreferences.shared
    try OEPreferences.shared.setValues(["importedA": true, "importedB": 2])
    let _: Error? = OEPreferences.shared.lastError
    let _: any OEPreferencesStore = UserDefaults.standard
    store.set("value", forKey: "a")
    store.set(true, forKey: "a")
    store.set(3.5, forKey: "a")
    store.set(root, forKey: "a")
    store.set(nil, forKey: "a")
    store.removeObject(forKey: "a")
    store.register(defaults: ["a": true])
    let _: Any? = store.object(forKey: "a")
    let _: String? = store.string(forKey: "a")
    let _: Bool = store.bool(forKey: "a")
    let _: Int = store.integer(forKey: "a")
    let _: Double = store.double(forKey: "a")
    let _: Float = store.float(forKey: "a")
    let _: Data? = store.data(forKey: "a")
    let _: [Any]? = store.array(forKey: "a")
    let _: [String: Any]? = store.dictionary(forKey: "a")
    let _: [String]? = store.stringArray(forKey: "a")
    let _: URL? = store.url(forKey: "a")
    let _: [String: Any] = store.dictionaryRepresentation()
    let _: [String: Any] = store.volatileDomain(forName: UserDefaults.registrationDomain)
    let _: Bool = store.synchronize()
    Task.detached { OEPreferences.shared.set(true, forKey: "b") }
}
