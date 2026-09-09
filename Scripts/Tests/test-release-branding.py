#!/usr/bin/env python3
"""Private release-metadata fixtures; never build, sign, publish or access keys."""

import os
import base64
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET


REPOSITORY = Path(__file__).resolve().parents[2]
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
PREVIOUS_ITEM = '''    <item>
      <title>OpenEmu-Silicon 1.2.5</title>
      <enclosure url="https://example.invalid/upstream/historical.dmg"
        sparkle:version="21" sparkle:shortVersionString="1.2.5"/>
    </item>'''
FIXTURE_FEED = '''<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>OpenEmu Reborn Changelog</title>
    <link>https://github.com/communism420/OpenEmu-Reborn/releases</link>
    <language>en</language>
''' + PREVIOUS_ITEM + '''
  </channel>
</rss>
'''


class ReleaseBrandingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='openemu-reborn-metadata-')
        self.addCleanup(self.directory.cleanup)
        self.appcast = Path(self.directory.name) / 'appcast.xml'
        self.appcast.write_text(FIXTURE_FEED, encoding='utf-8')

    def update(self, version='1.0.0', build='22', **overrides):
        # Exercise only the pure metadata renderer. The real CLI now refuses
        # to advertise an archive until its signature and public asset match.
        module = runpy.run_path(str(REPOSITORY / 'Scripts/update_appcast.py'))
        repository = overrides.get('OPENEMU_RELEASE_REPO', 'communism420/OpenEmu-Reborn')
        archive = overrides.get('OPENEMU_DMG_NAME', 'OpenEmu-Reborn.dmg')
        result = module['render_feed'](
            self.appcast.read_text(encoding='utf-8'), version, build,
            'Sun, 06 Sep 2026 12:00:00 +0000', base64.b64encode(bytes(64)).decode(),
            '1234', '<p>Fixture notes</p>',
            f'https://github.com/{repository}/releases/download/v{version}/{archive}', 'universal')
        self.appcast.write_text(result, encoding='utf-8')
        return ET.parse(self.appcast).findall('./channel/item')

    def next_build_from_release_script(self):
        source = (REPOSITORY / 'Scripts/release.sh').read_text(encoding='utf-8')
        # Execute only the actual read-only build-counter calculation, not the
        # release entry point (which builds, accesses credentials and publishes).
        calculation = re.search(r'^CURRENT_MAX=.*\nNEXT_VERSION=.*$', source, re.MULTILINE)
        self.assertIsNotNone(calculation, 'Release build-counter calculation moved; update this focused test')
        result = subprocess.run(
            ['/bin/bash', '-c', 'set -euo pipefail\n' + calculation.group(0) + '\nprintf "%s" "$NEXT_VERSION"'],
            env={**os.environ, 'APPCAST': str(self.appcast)}, capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_reborn_one_point_zero_keeps_monotonic_build_counter(self):
        self.assertEqual(self.next_build_from_release_script(), '22')
        items = self.update()
        self.assertEqual(len(items), 2)
        self.assertEqual(items[0].findtext('title'), 'OpenEmu Reborn 1.0.0')
        self.assertIn('<h2>OpenEmu Reborn 1.0.0</h2>', items[0].findtext('description'))
        enclosure = items[0].find('enclosure')
        self.assertEqual(enclosure.get('url'),
                         'https://github.com/communism420/OpenEmu-Reborn/releases/download/v1.0.0/OpenEmu-Reborn.dmg')
        self.assertEqual(enclosure.get(f'{{{SPARKLE}}}version'), '22')
        self.assertEqual(enclosure.get(f'{{{SPARKLE}}}shortVersionString'), '1.0.0')
        self.assertIn(PREVIOUS_ITEM.lstrip(), self.appcast.read_text(encoding='utf-8'))
        self.assertEqual(self.next_build_from_release_script(), '23')
        items = self.update('1.0.1', '23')
        self.assertEqual(items[0].find('enclosure').get(f'{{{SPARKLE}}}version'), '23')
        self.assertEqual(items[1].find('enclosure').get(f'{{{SPARKLE}}}version'), '22')
        self.assertEqual(items[2].find('enclosure').get(f'{{{SPARKLE}}}version'), '21')
        self.assertEqual(self.next_build_from_release_script(), '24')

    def test_explicit_release_location_override_still_works(self):
        items = self.update(OPENEMU_RELEASE_REPO='fixture-owner/fixture-repo', OPENEMU_DMG_NAME='Custom.dmg')
        self.assertEqual(items[0].find('enclosure').get('url'),
                         'https://github.com/fixture-owner/fixture-repo/releases/download/v1.0.0/Custom.dmg')

    def test_packaging_defaults_agree_without_renaming_persistent_identity(self):
        release = (REPOSITORY / 'Scripts/release.sh').read_text(encoding='utf-8')
        notarize = (REPOSITORY / 'Scripts/notarize.sh').read_text(encoding='utf-8')
        make_dmg = (REPOSITORY / 'Scripts/make-dmg.sh').read_text(encoding='utf-8')
        package = (REPOSITORY / 'Scripts/package-intel-test-build.sh').read_text(encoding='utf-8')
        self.assertIn('RELEASE_REPO="${OPENEMU_RELEASE_REPO:-communism420/OpenEmu-Reborn}"', release)
        for script in (release, notarize):
            self.assertIn('DMG_NAME="${OPENEMU_DMG_NAME:-OpenEmu-Reborn.dmg}"', script)
            # This is an existing Keychain credential name, not display branding.
            self.assertIn('${OPENEMU_NOTARY_PROFILE:-OpenEmu-Intel}', script)
        self.assertIn('VOLNAME="OpenEmu Reborn"', make_dmg)
        self.assertIn('PACKAGE="$OUTPUT/OpenEmu-Intel-test"', package)
        self.assertIn('archive="OpenEmu-Reborn-Intel-test-${commit:0:12}.zip"', package)
        with mock.patch.dict(os.environ, {'APP_PATH': '/fixture/OpenEmu.app', 'BG_PATH': '/fixture/background.png'}):
            settings = runpy.run_path(str(REPOSITORY / 'Scripts/dmg-assets/dmgbuild_settings.py'))
        self.assertEqual(settings['volume_name'], 'OpenEmu Reborn')
        self.assertEqual(settings['files'], ['/fixture/OpenEmu.app'])
        self.assertIn('OpenEmu.app', settings['icon_locations'])


if __name__ == '__main__':
    unittest.main()
