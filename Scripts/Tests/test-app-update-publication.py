#!/usr/bin/env python3
"""Offline publication guards: no builds, private keys, network or Git writes."""
import base64
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile

REPOSITORY = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('update_appcast', REPOSITORY / 'Scripts/update_appcast.py')
UPDATER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPDATER)
ARCHIVE_READER = importlib.import_module('update_archive')
KEY = base64.b64encode(bytes(range(32))).decode()
SIGNATURE = base64.b64encode(bytes(range(64))).decode()
RELEASE_REPO = 'fixture-owner/fixture-repo'
ARCHIVE = 'OpenEmu-Reborn-universal.zip'
URL = f'https://github.com/{RELEASE_REPO}/releases/download/v1.0.0/{ARCHIVE}'
FEED = '''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<language>en</language><item><enclosure sparkle:version="21"/></item></channel></rss>'''
RELEASE = {'draft': False, 'prerelease': False, 'assets': [
    {'name': ARCHIVE, 'state': 'uploaded', 'size': 1234, 'digest': 'sha256:abc', 'browser_download_url': URL}]}


class PublicationTests(unittest.TestCase):
    def test_public_asset_must_match_signed_local_archive(self):
        with mock.patch.object(UPDATER, 'urlopen', return_value=io.BytesIO(json.dumps(RELEASE).encode())) as request:
            self.assertEqual(UPDATER.published_asset_url(RELEASE_REPO, '1.0.0', ARCHIVE, 1234, 'abc'), URL)
            self.assertNotIn('Authorization', request.call_args.args[0].headers)

    def test_draft_prerelease_missing_wrong_size_hash_url_or_state_are_rejected(self):
        changes = [({'draft': True}, None), ({'prerelease': True}, None), ({'assets': []}, None),
                   ({}, {'size': 1235}), ({}, {'digest': 'sha256:wrong'}), ({}, {'digest': None}),
                   ({}, {'browser_download_url': 'https://example.invalid/wrong.zip'}), ({}, {'state': 'new'})]
        for release_change, asset_change in changes:
            with self.subTest(release_change=release_change, asset_change=asset_change):
                release = copy.deepcopy(RELEASE)
                release.update(release_change)
                if asset_change:
                    release['assets'][0].update(asset_change)
                with mock.patch.object(UPDATER, 'urlopen', return_value=io.BytesIO(json.dumps(release).encode())):
                    with self.assertRaises(ValueError):
                        UPDATER.published_asset_url(RELEASE_REPO, '1.0.0', ARCHIVE, 1234, 'abc')

    def test_inherited_and_malformed_signatures_keys_versions_are_rejected(self):
        valid = ['1.0.0', '23', SIGNATURE, '1234', 'universal', KEY]
        UPDATER.validate_metadata(*valid)
        for index, value in [(0, 'invalid'), (1, '0'), (1, '-1'), (2, 'unsigned'), (3, '0'),
                             (4, 'all'), (5, UPDATER.INHERITED_KEY), (5, 'bad')]:
            with self.subTest(index=index, value=value):
                values = valid.copy()
                values[index] = value
                with self.assertRaises(ValueError):
                    UPDATER.validate_metadata(*values)

    def test_build_counter_can_skip_unpublished_local_build_22(self):
        result = UPDATER.render_feed(FEED, '1.0.0', '23', 'date', SIGNATURE, '1234', 'notes', URL, 'universal')
        self.assertIn('sparkle:version="23"', result)
        for build in ('21', '20', '23'):
            with self.assertRaises(ValueError):
                UPDATER.render_feed(result, '1.0.0', build, 'date', SIGNATURE, '1234', 'notes', URL, 'universal')

    def test_intel_thin_archive_cannot_be_advertised_in_shared_feed(self):
        with self.assertRaisesRegex(ValueError, 'does not enforce'):
            UPDATER.validate_feed_architecture(REPOSITORY / 'appcast.xml', 'x86_64')
        UPDATER.validate_feed_architecture(REPOSITORY / 'appcast-x86_64.xml', 'x86_64')
        UPDATER.validate_feed_architecture(REPOSITORY / 'appcast.xml', 'universal')
        with self.assertRaisesRegex(ValueError, 'SUFeedURL'):
            UPDATER.validate_feed_architecture(REPOSITORY / 'appcast-x86_64.xml', 'x86_64',
                'https://raw.githubusercontent.com/communism420/OpenEmu-Reborn/main/appcast.xml')

    def test_arm64_requirement_is_explicit_and_universal_has_none(self):
        arm = UPDATER.render_feed(FEED, '1.0.0', '23', 'date', SIGNATURE, '1234', 'notes', URL, 'arm64')
        self.assertIn('<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>', arm)
        universal = UPDATER.render_feed(FEED, '1.0.0', '23', 'date', SIGNATURE, '1234', 'notes', URL, 'universal')
        self.assertNotIn('hardwareRequirements', universal)

    def test_signature_verification_failure_stops_before_published_asset_query(self):
        with tempfile.TemporaryDirectory(prefix='reborn-update-publication-') as directory:
            archive = Path(directory) / ARCHIVE
            archive.write_bytes(b'not signed')
            with mock.patch.object(UPDATER.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'swift')):
                with self.assertRaises(subprocess.CalledProcessError):
                    UPDATER.verify_archive(archive, SIGNATURE, archive.stat().st_size, KEY)

    def test_archive_size_is_checked_before_signature_tool(self):
        with tempfile.TemporaryDirectory(prefix='reborn-update-publication-') as directory:
            archive = Path(directory) / ARCHIVE
            archive.write_bytes(b'test')
            with mock.patch.object(UPDATER.subprocess, 'run') as verifier:
                with self.assertRaises(ValueError):
                    UPDATER.verify_archive(archive, SIGNATURE, 5, KEY)
                verifier.assert_not_called()

    def test_script_mode_dispatch_happens_before_paid_developer_preflight(self):
        release = (REPOSITORY / 'Scripts/release.sh').read_text()
        self.assertLess(release.index('= "--self-signed"'), release.index('xcrun notarytool history'))
        self.assertIn('org.openemu.Reborn.updates', release)
        preparer = (REPOSITORY / 'Scripts/prepare-self-signed-update.sh').read_text()
        for command in ['xcodebuild', 'notarytool', 'security find-', 'codesign --force', 'gh release create']:
            self.assertNotIn(command, preparer)
        self.assertIn('--test-requirement', preparer)
        self.assertIn('verify-bundle-architectures.sh', preparer)

    def test_failed_advertisement_does_not_change_feed(self):
        with tempfile.TemporaryDirectory(prefix='reborn-advertise-fixture-') as directory:
            root = Path(directory).resolve()
            feed = root / 'appcast.xml'
            feed.write_text(FEED)
            manifest = root / 'prepared.json'
            manifest.write_text(json.dumps({
                'schema': 1, 'version': '1.0.0', 'build': '23', 'public_key': KEY,
                'signature': SIGNATURE, 'archive': str(root / ARCHIVE), 'length': 1234,
                'architecture': 'universal', 'appcast': str(feed), 'notes_html': 'fixture notes',
                'repository': RELEASE_REPO, 'sha256': 'abc'}))
            draft = {**RELEASE, 'draft': True}
            with mock.patch.object(UPDATER, 'REPOSITORY', root), \
                 mock.patch.object(UPDATER, 'check_source_key'), \
                 mock.patch.object(UPDATER, 'verify_archive', return_value='abc'), \
                 mock.patch.object(UPDATER, 'validate_archive_app'), \
                 mock.patch.object(UPDATER.subprocess, 'check_output', return_value='codex/release-fixture\n'), \
                 mock.patch.object(UPDATER, 'urlopen', return_value=io.BytesIO(json.dumps(draft).encode())):
                with self.assertRaises(ValueError):
                    UPDATER.advertise_manifest(manifest)
            self.assertEqual(feed.read_text(), FEED)


class ArchiveHandlingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='reborn-update-archive-fixture-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.archive = self.root / 'update.zip'

    def make_zip(self, extras=()):
        with zipfile.ZipFile(self.archive, 'w') as archive:
            archive.writestr('OpenEmu.app/Contents/Info.plist', plistlib.dumps({'fixture': True}))
            for name, payload, mode in extras:
                entry = zipfile.ZipInfo(name)
                entry.external_attr = mode << 16
                archive.writestr(entry, payload)

    def test_single_app_and_appledouble_are_inspected_then_removed(self):
        self.make_zip([('__MACOSX/OpenEmu.app/Contents/._Info.plist', b'fixture resource fork', stat.S_IFREG | 0o644)])
        with ARCHIVE_READER.extracted_update_app(self.archive) as app:
            self.assertTrue((app / 'Contents/Info.plist').is_file())
            self.assertFalse((app.parent / '__MACOSX').exists())
            inspected = app
        self.assertFalse(inspected.exists())

    def test_traversal_second_app_aliases_and_external_symlinks_are_rejected(self):
        for name, payload, mode in [
            ('../outside', b'bad', stat.S_IFREG | 0o644),
            ('Other.app/Contents/Info.plist', b'bad', stat.S_IFREG | 0o644),
            ('__MACOSX/Other.app/Contents/Info.plist', b'bad', stat.S_IFREG | 0o644),
            ('OpenEmu.app/Contents/info.plist', b'case alias', stat.S_IFREG | 0o644),
            ('OpenEmu.app/Contents/secret', b'/etc/passwd', stat.S_IFLNK | 0o777),
            ('OpenEmu.app/Contents/pipe', b'', stat.S_IFIFO | 0o644)]:
            with self.subTest(name=name):
                self.make_zip([(name, payload, mode)])
                with self.assertRaises((ValueError, OSError)):
                    with ARCHIVE_READER.extracted_update_app(self.archive):
                        self.fail('Unsafe archive was accepted')
        self.assertFalse((self.root.parent / 'outside').exists())

    def test_zip_is_cleaned_up_after_validation_failure(self):
        self.make_zip()
        with self.assertRaisesRegex(ValueError, 'fixture validation'):
            with ARCHIVE_READER.extracted_update_app(self.archive) as app:
                inspected = app
                raise ValueError('fixture validation failed')
        self.assertFalse(inspected.exists())

    def test_dmg_is_readonly_and_detached_even_after_validation_failure(self):
        dmg = self.root / 'fixture.dmg'
        dmg.write_bytes(b'fixture; never mounted by a real tool')
        calls = []

        def mock_disk_tool(command, **kwargs):
            calls.append(command)
            self.assertEqual(command[0], 'hdiutil')
            if command[1] == 'attach':
                for flag in ('-readonly', '-nobrowse', '-noautoopen'):
                    self.assertIn(flag, command)
                mountpoint = Path(command[command.index('-mountpoint') + 1])
                (mountpoint / 'OpenEmu.app/Contents').mkdir(parents=True)
                (mountpoint / 'OpenEmu.app/Contents/Info.plist').write_bytes(plistlib.dumps({'fixture': True}))
                return subprocess.CompletedProcess(command, 0, stdout=plistlib.dumps({'system-entities': []}))
            self.assertEqual(command[1], 'detach')
            return subprocess.CompletedProcess(command, 0)

        with mock.patch.object(ARCHIVE_READER.subprocess, 'run', side_effect=mock_disk_tool):
            with self.assertRaisesRegex(ValueError, 'fixture validation'):
                with ARCHIVE_READER.extracted_update_app(dmg) as app:
                    inspected = app
                    raise ValueError('fixture validation failed')
        self.assertEqual([call[1] for call in calls], ['attach', 'detach'])
        self.assertEqual(calls[1][2], calls[0][calls[0].index('-mountpoint') + 1])
        self.assertFalse(inspected.exists())

    def test_main_and_detached_head_cannot_advertise(self):
        for branch in ('main\n', ''):
            with mock.patch.object(UPDATER.subprocess, 'check_output', return_value=branch):
                with self.assertRaises(ValueError):
                    UPDATER.require_feature_branch()

    def test_old_signed_archive_cannot_advertise_a_new_build_via_edited_manifest(self):
        with tempfile.TemporaryDirectory(prefix='reborn-archive-binding-') as directory:
            root = Path(directory).resolve()
            feed = root / 'appcast.xml'
            feed.write_text(FEED)
            archive = root / ARCHIVE
            app_info = {'CFBundleIdentifier': 'org.openemu.OpenEmu', 'CFBundleShortVersionString': '1.0.0',
                'CFBundleVersion': '22', 'SUPublicEDKey': KEY,
                'SUFeedURL': 'https://raw.githubusercontent.com/communism420/OpenEmu-Reborn/main/appcast.xml'}
            with zipfile.ZipFile(archive, 'w') as zipped:
                zipped.writestr('OpenEmu.app/Contents/Info.plist', plistlib.dumps(app_info))
            metadata = {'schema': 1, 'version': '1.0.0', 'build': '23', 'public_key': KEY,
                'signature': SIGNATURE, 'archive': str(archive), 'length': archive.stat().st_size,
                'architecture': 'universal', 'appcast': str(feed), 'notes_html': 'fixture notes',
                'repository': RELEASE_REPO, 'sha256': 'abc'}
            manifest = root / 'prepared.json'
            manifest.write_text(json.dumps(metadata))
            with mock.patch.object(UPDATER, 'REPOSITORY', root), \
                 mock.patch.object(UPDATER, 'check_source_key'), \
                 mock.patch.object(UPDATER, 'verify_archive', return_value='abc'), \
                 mock.patch.object(UPDATER.subprocess, 'check_output', return_value='codex/release-fixture\n'), \
                 mock.patch.object(UPDATER, 'published_asset_url') as publish:
                with self.assertRaisesRegex(ValueError, 'Archived app CFBundleVersion'):
                    UPDATER.advertise_manifest(manifest)
                publish.assert_not_called()
            self.assertEqual(feed.read_text(), FEED)


if __name__ == '__main__':
    unittest.main()
