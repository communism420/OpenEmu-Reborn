#!/usr/bin/env python3
# Copyright (c) 2026, OpenEmu Team
# SPDX-License-Identifier: BSD-2-Clause
"""Read-only app branding checks; no build, launch, signing or Keychain access.

Run without arguments for the first Reborn release. Future releases can pass
--expected-version and --expected-build without rewriting these invariants.
--app compares an existing Release app and every localization catalog to source.
"""

import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


REPOSITORY = Path(__file__).resolve().parents[2]
BRAND = 'OpenEmu Reborn'
BUNDLE_ID = 'org.openemu.OpenEmu'
SPARKLE_KEY = 'C1aUBkg5G0afqAq9XhxxFKaDO0PsMRAxmLkMUdKSIC4='
CORE_CATALOG = 'https://raw.githubusercontent.com/OpenEmu-Silicon/OpenEmu-Silicon/main/oecores.xml'
MENU_KEYS = ('About OpenEmu', 'Hide OpenEmu', 'Quit OpenEmu', 'OpenEmu Web Site')


def read(relative):
    return (REPOSITORY / relative).read_text(encoding='utf-8')


def plist(path):
    with path.open('rb') as stream:
        return plistlib.load(stream)


def localization_catalog(path):
    # Xcode may emit binary .strings; the system-plugin post-install tool emits
    # OpenStep InfoPlist.strings. Compare parsed values, not file encodings.
    try:
        values = plist(path)
    except plistlib.InvalidFileException:
        result = subprocess.run(
            ['/usr/bin/plutil', '-convert', 'xml1', '-o', '-', '--', str(path)],
            capture_output=True, check=False)
        if result.returncode:
            raise ValueError(f'{path}: invalid localization catalog: '
                             + result.stderr.decode(errors='replace'))
        values = plistlib.loads(result.stdout)
    if not isinstance(values, dict) or any(
            not isinstance(key, str) or not isinstance(value, str)
            for key, value in values.items()):
        raise ValueError(f'{path}: expected a dictionary of localized strings')
    return values


def catalog_differences(expected, actual, *, allow_generated_entries=False):
    differences = []
    for key, value in expected.items():
        if key not in actual:
            differences.append(f'Missing key: {key!r}')
        elif actual[key] != value:
            differences.append(f'Changed value for {key!r}: {actual[key]!r} != {value!r}')
    if not allow_generated_entries:
        for key in sorted(actual.keys() - expected.keys()):
            differences.append(f'Unexpected key: {key!r}')
    return differences


class LocalizationCatalogComparisonTests(unittest.TestCase):
    def test_xml_binary_and_openstep_are_compared_as_strings(self):
        values = {'Arcade Game': '街机游戏', 'Quoted': 'First\n"Second"'}
        with tempfile.TemporaryDirectory(prefix='openemu-catalog-comparison-') as directory:
            path = Path(directory) / 'InfoPlist.strings'
            for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
                path.write_bytes(plistlib.dumps(values, fmt=fmt))
                self.assertEqual(localization_catalog(path), values)
            path.write_text('"Arcade Game" = "街机游戏";\n'
                            '"Quoted" = "First\\n\\"Second\\"";\n', encoding='utf-8')
            self.assertEqual(localization_catalog(path), values)

    def test_generated_entries_do_not_allow_overwriting_source_translations(self):
        expected = {'Arcade Game': '街机游戏'}
        generated = {**expected, 'Wii Game': 'Wii 游戏'}
        self.assertEqual(catalog_differences(expected, generated,
                                            allow_generated_entries=True), [])
        generated['Arcade Game'] = 'Arcade 游戏'
        self.assertEqual(len(catalog_differences(expected, generated,
                                               allow_generated_entries=True)), 1)

    def test_missing_source_keys_and_unexpected_non_info_keys_are_rejected(self):
        self.assertEqual(catalog_differences({'New': 'Nouveau'}, {}), ["Missing key: 'New'"])
        self.assertEqual(catalog_differences({}, {'Stale': 'Old'}), ["Unexpected key: 'Stale'"])

    def test_non_string_catalog_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='openemu-catalog-comparison-') as directory:
            path = Path(directory) / 'Invalid.strings'
            path.write_bytes(plistlib.dumps({'Invalid': 42}))
            with self.assertRaisesRegex(ValueError, 'dictionary of localized strings'):
                localization_catalog(path)


def build_components(value):
    # Xcode can normalize 22 to 22.0; these are the same build number.
    if not isinstance(value, str) or not re.fullmatch(r'\d+(?:\.\d+){0,2}', value):
        raise ValueError(f'Expected a numeric build counter, got {value!r}')
    parts = [int(part) for part in value.split('.')]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


class RebornAppBrandingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.info = plist(REPOSITORY / 'OpenEmu/OpenEmu-Info.plist')

    def test_public_version_is_separate_from_monotonic_build(self):
        self.assertEqual(self.info['CFBundleShortVersionString'], OPTIONS.expected_version)
        self.assertEqual(build_components(self.info['CFBundleVersion']),
                         build_components(OPTIONS.expected_build))
        self.assertGreater(build_components(self.info['CFBundleVersion']), (21,))
        about = read('OpenEmu/AboutViewController.swift')
        getter = re.search(r'var appVersion:\s*String\s*\{(.*?)\n\s*\}', about, re.DOTALL)
        self.assertIsNotNone(getter, 'About version getter moved; update this focused check')
        self.assertIn('"CFBundleShortVersionString"', getter.group(1))
        self.assertNotIn('"CFBundleVersion"', getter.group(1))

    def test_brand_changes_do_not_rename_executable_or_module(self):
        self.assertEqual(self.info['CFBundleDisplayName'], BRAND)
        self.assertEqual(self.info['CFBundleName'], BRAND)
        self.assertEqual(self.info['CFBundleExecutable'], '$(EXECUTABLE_NAME)')
        self.assertEqual(self.info['CFBundleIdentifier'], '$(PRODUCT_BUNDLE_IDENTIFIER)')
        self.assertEqual(self.info['NSPrincipalClass'], 'OEApplication')
        document_classes = [item['NSDocumentClass'] for item in self.info['CFBundleDocumentTypes']
                            if 'NSDocumentClass' in item]
        self.assertTrue(document_classes)
        self.assertTrue(all(name.startswith('OpenEmu.') for name in document_classes))
        project = read('OpenEmu/OpenEmu.xcodeproj/project.pbxproj')
        configurations = [block for block in re.findall(r'buildSettings\s*=\s*\{(.*?)\n\s*\};', project, re.DOTALL)
                          if 'INFOPLIST_FILE = "OpenEmu-Info.plist";' in block]
        self.assertGreaterEqual(len(configurations), 2)
        for block in configurations:
            self.assertIn('PRODUCT_NAME = OpenEmu;', block)
            self.assertIn(f'MARKETING_VERSION = {OPTIONS.expected_version};', block)
            identifier = re.search(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(.*?);', block).group(1).strip('"')
            self.assertIn(identifier, (BUNDLE_ID, BUNDLE_ID + '.debug', 'org.openemu.$(PRODUCT_NAME:identifier)'))
        for filename in ('Main.storyboard', 'MainWindow.xib', 'SetupAssistant.xib'):
            tree = ET.fromstring(read('OpenEmu/' + filename))
            modules = {element.get('customModule') for element in tree.iter() if element.get('customModule')}
            self.assertIn('OpenEmu', modules)
            self.assertFalse(any('Reborn' in module for module in modules))

    def test_update_trust_does_not_rename_local_signing_identity(self):
        self.assertEqual(self.info['SUPublicEDKey'], SPARKLE_KEY)
        self.assertEqual(self.info['OECoreListURL'], CORE_CATALOG)
        self.assertEqual(self.info['SUFeedURL'],
                         'https://raw.githubusercontent.com/communism420/OpenEmu-Reborn/main/appcast.xml')
        updater = read('OpenEmu/CoreUpdater.swift')
        self.assertIn('OECoreUpdateSecurity.catalogURL()', updater)
        self.assertNotIn('OpenEmu-Update/master/oecores.xml', updater)
        for arch in ('arm64', 'x86_64'):
            self.assertEqual(self.info['OECoreUpdateCatalogs'][arch],
                             f'https://raw.githubusercontent.com/communism420/OpenEmu-Reborn/main/Updates/cores/{arch}/oecores.xml')
        self.assertTrue(self.info['SUVerifyUpdateBeforeExtraction'])
        self.assertNotIn('refreshStaleCoreFeedURLs', read('OpenEmu/AppDelegate.swift'))
        identity = read('Scripts/Signing/CreateSigningIdentity.swift')
        self.assertIn('"OpenEmu-Intel Local Signing"', identity)
        self.assertIn('"org.openemu.OpenEmu-Intel.local-code-signing.v1"', identity)

    def test_localized_menus_and_primary_windows(self):
        menus = list((REPOSITORY / 'OpenEmu').glob('*.lproj/MainMenu.strings'))
        self.assertTrue(menus)
        for path in menus:
            values = plist(path)
            for key in MENU_KEYS:
                self.assertIn(BRAND, values[key], f'{path.parent.name}: {key}')
        for path in (REPOSITORY / 'OpenEmu').glob('*.lproj/InfoPlist.strings'):
            values = plist(path)
            for key in ('CFBundleName', 'CFBundleDisplayName'):
                if key in values:
                    self.assertEqual(values[key], BRAND, str(path))
        main = read('OpenEmu/Main.storyboard')
        self.assertIn('OpenEmu Reborn v%{value1}@', main)
        self.assertIn('github.com/communism420/OpenEmu-Reborn', main)
        window = ET.fromstring(read('OpenEmu/MainWindow.xib')).find('.//window')
        self.assertEqual(window.get('title'), BRAND)
        self.assertIn('Welcome to OpenEmu Reborn', read('OpenEmu/SetupAssistant.xib'))

    def test_display_name_is_not_a_credential_or_storage_identifier(self):
        credentials = read('OpenEmu/OECredentialStore.swift')
        self.assertIn('Bundle.main.bundleIdentifier', credentials)
        self.assertIn('"OpenEmu-CredentialStore-v1"', credentials)
        self.assertNotIn('CFBundleName', credentials)
        self.assertNotIn('CFBundleDisplayName', credentials)
        for service in ('com.openemu.ScreenScraper', 'com.openemu.RetroAchievements', 'com.openemu.GoogleDriveSaveSync'):
            self.assertIn(f'"{service}"', credentials)
        storage = read('OpenEmu-SDK/OpenEmuBase/OEStoragePaths.m')
        self.assertNotIn('CFBundleName', storage)
        self.assertIn('URLByAppendingPathComponent:@"OpenEmu"', storage)
        setup = read('OpenEmu/OEDataFolderSetup.swift')
        self.assertIn('bootstrapDomain = "org.openemu.OpenEmu"', setup)
        shader = read('OpenEmuKit/Source/OEShaderStore.swift')
        for property_name, managed_path in (('userShadersPath', 'OEStoragePaths.dataRootURL'),
                                            ('shadersCachePath', 'OEStoragePaths.cachesURL')):
            body = shader.split(f'var {property_name}: URL?', 1)[1]
            configured = body.index('if OEStoragePaths.isConfigured')
            selected_path = body.index(managed_path)
            fallback = body.index('userPathName')
            self.assertLess(configured, selected_path)
            self.assertLess(selected_path, fallback)

    def test_existing_release_app_matches_source(self):
        if OPTIONS.app is None:
            self.skipTest('Pass --app /absolute/OpenEmu.app for packaged-resource checks')
        app = OPTIONS.app
        self.assertTrue(app.is_absolute(), '--app must be an explicit absolute path')
        self.assertEqual(app.name, 'OpenEmu.app')
        actual = plist(app / 'Contents/Info.plist')
        for key in ('CFBundleName', 'CFBundleDisplayName', 'CFBundleShortVersionString',
                    'SUPublicEDKey', 'OECoreListURL', 'OECoreUpdateCatalogs', 'SUFeedURL', 'SUVerifyUpdateBeforeExtraction'):
            self.assertEqual(actual[key], self.info[key], key)
        self.assertEqual(build_components(actual['CFBundleVersion']), build_components(self.info['CFBundleVersion']))
        self.assertEqual(actual['CFBundleIdentifier'], BUNDLE_ID)
        self.assertEqual(actual['CFBundleExecutable'], 'OpenEmu')
        self.assertTrue((app / 'Contents/MacOS/OpenEmu').is_file())
        resources = app / 'Contents/Resources'
        self.assertTrue((resources / 'Main.storyboardc').is_dir())
        for source in (REPOSITORY / 'OpenEmu').glob('*.lproj/MainMenu.strings'):
            expected = plist(source)
            actual_menu = plist(resources / source.parent.name / source.name)
            for key in MENU_KEYS:
                self.assertEqual(actual_menu[key], expected[key], f'{source.parent.name}: {key}')

    def test_existing_release_app_preserves_all_localization_catalogs(self):
        if OPTIONS.app is None:
            self.skipTest('Pass --app /absolute/OpenEmu.app for packaged-resource checks')
        self.assertTrue(OPTIONS.app.is_absolute(), '--app must be an explicit absolute path')
        sources = sorted((REPOSITORY / 'OpenEmu').glob('*.lproj/*.strings'))
        self.assertTrue(sources, 'No source localization catalogs found')
        resources = OPTIONS.app / 'Contents/Resources'
        for source in sources:
            relative = Path(source.parent.name) / source.name
            with self.subTest(catalog=str(relative)):
                built = resources / relative
                self.assertTrue(built.is_file(), f'Missing packaged catalog: {relative}')
                self.assertEqual(catalog_differences(
                    localization_catalog(source), localization_catalog(built),
                    allow_generated_entries=source.name == 'InfoPlist.strings'), [])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected-version', default='1.0.1')
    parser.add_argument('--expected-build', default='24')
    parser.add_argument('--app', type=Path)
    OPTIONS = parser.parse_args()
    unittest.main(argv=['test-reborn-app-branding.py'], verbosity=2)
