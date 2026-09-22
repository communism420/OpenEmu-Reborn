#!/usr/bin/env python3
"""Source integration guards; no app, game, data-folder or signing-key access."""
from pathlib import Path
import plistlib
import re
import json
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text()


class SiliconSyncTests(unittest.TestCase):
    def test_native_and_external_plugin_paths_remain_wired(self):
        for path in ('OpenEmu-SDK/OpenEmuBase/OELibretroCoreTranslator.h',
                     'OpenEmu-SDK/OpenEmuBase/OELibretroCoreTranslator.m',
                     'OpenEmu-SDK/OpenEmuBase/libretro.h',
                     'OpenEmu/LibretroBridge/OpenEmuLibretroBridgeMain.m',
                     'OpenEmu/OELibretroMetadata.swift'):
            self.assertTrue((ROOT / path).is_file(), path)
        sdk = source('OpenEmu-SDK/OpenEmu-SDK.xcodeproj/project.pbxproj')
        self.assertIn('OELibretroCoreTranslator.m in Sources', sdk)
        project = json.loads(subprocess.check_output([
            '/usr/bin/plutil', '-convert', 'json', '-o', '-',
            str(ROOT / 'OpenEmu/OpenEmu.xcodeproj/project.pbxproj')]))['objects']
        bridge = next(item for item in project.values()
                      if item.get('isa') == 'PBXNativeTarget' and item.get('name') == 'OpenEmuLibretroBridge')
        host = next(item for item in project.values()
                    if item.get('isa') == 'PBXNativeTarget' and item.get('name') == 'OpenEmu')
        copies = [project[phase] for phase in host['buildPhases']
                  if project[phase]['isa'] == 'PBXCopyFilesBuildPhase']
        copied_products = [project[file].get('fileRef') for phase in copies for file in phase['files']]
        self.assertIn(bridge['productReference'], copied_products)
        picker = source('OpenEmu/PrefCoresController.swift')
        for token in ('scanRetroArchCores()', 'installRetroArchPlugin(', 'OELibretroCorePath', 'OEGameCoreClass'):
            self.assertIn(token, picker)
        self.assertIn('OECorePlugin', picker)

    def test_no_retroarch_removal_sweep_or_retirement(self):
        delegate = source('OpenEmu/AppDelegate.swift')
        self.assertNotIn('removeOrphanedRetroArchPlugins', delegate)
        self.assertLess(delegate.index('refreshStaleRetroArchStubs()'),
                        delegate.index('OECorePlugin.registerClass()'))
        document = source('OpenEmu/OEGameDocument.swift')
        expression = re.search(r'let isRetiredCore = ([^\n]+)', document)
        self.assertIsNotNone(expression)
        self.assertEqual(expression[1], 'identifier.hasSuffix("-Bridge")')
        self.assertIn('runWithCore(core, nil)', document)
        self.assertIn('isEmulationPaused = false', document)

    def test_reborn_update_trust_is_not_replaced_by_plugin_feeds(self):
        info = plistlib.loads((ROOT / 'OpenEmu/OpenEmu-Info.plist').read_bytes())
        for architecture in ('arm64', 'x86_64'):
            self.assertEqual(info['OECoreUpdateCatalogs'][architecture],
                             f'https://raw.githubusercontent.com/communism420/OpenEmu-Reborn/main/Updates/cores/{architecture}/oecores.xml')
        self.assertEqual(info['SUPublicEDKey'], 'C1aUBkg5G0afqAq9XhxxFKaDO0PsMRAxmLkMUdKSIC4=')
        self.assertNotIn('refreshStaleCoreFeedURLs', source('OpenEmu/AppDelegate.swift'))
        security = source('OpenEmu/OECoreUpdateSecurity.swift')
        self.assertIn('key.isValidSignature(signatureData, for: archive)', security)

    def test_new_cheat_storage_obeys_profile_lifecycle(self):
        for path in ('OpenEmu/CheatFeedbackService.swift', 'OpenEmu/LibretroCheatProvider.swift'):
            text = source(path)
            self.assertIn('oeCreateDirectory', text)
            self.assertNotIn('createDirectory(at:', text)
            self.assertNotIn('URLSession.shared', text)
        delegate = source('OpenEmu/AppDelegate.swift')
        self.assertIn('"CheatDatabase"', delegate)
        self.assertIn('"CheatFeedback"', delegate)

    def test_one_localized_core_update_error_implementation(self):
        updater = source('OpenEmu/CoreUpdater.swift')
        self.assertEqual(updater.count('var errorDescription: String?'), 1)
        self.assertIn('enum Errors: LocalizedError', updater)
        self.assertNotIn('extension CoreUpdater.Errors: LocalizedError', updater)


if __name__ == '__main__':
    unittest.main(verbosity=2)
