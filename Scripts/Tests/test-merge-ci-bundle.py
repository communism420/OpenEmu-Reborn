#!/usr/bin/env python3
"""Private CI-pair merge fixtures; no real apps, builds, signing or downloads."""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile

REPOSITORY = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('merge_ci_bundle', REPOSITORY / 'Scripts/merge-ci-bundle.py')
MERGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MERGER)
SHA = 'a' * 40
REPO = 'communism420/OpenEmu-Reborn'


class BundleMergeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='reborn-merge-fixture-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.make_artifact('arm64')
        self.make_artifact('x86_64')
        self.args = argparse.Namespace(arm64_artifact=self.root / 'arm64', x86_64_artifact=self.root / 'x86_64',
            source_sha=SHA, repository=REPO, output=self.root / 'result')

    def make_artifact(self, arch):
        source = self.root / f'source-{arch}/Nestopia.oecoreplugin'
        (source / 'Contents/MacOS').mkdir(parents=True)
        (source / 'Contents/Resources').mkdir()
        (source / 'Contents/_CodeSignature').mkdir()
        (source / 'Contents/_CodeSignature/CodeResources').write_bytes(arch.encode())
        # Non-executable Mach-O object header, sufficient for lipo fixtures.
        # No compiler is called and this object is never loaded or executed.
        cpu, subtype = (0x0100000c, 0) if arch == 'arm64' else (0x01000007, 3)
        (source / 'Contents/MacOS/Nestopia').write_bytes(struct.pack('<IiiIIIII', 0xfeedfacf, cpu, subtype, 1, 0, 0, 0, 0))
        (source / 'Contents/Resources/data.txt').write_text('same game-independent fixture resource')
        info = {'CFBundleIdentifier': 'org.openemu.Nestopia', 'CFBundleVersion': '1.2.3', 'CFBundleShortVersionString': '1.2.3',
                'CFBundleExecutable': 'Nestopia', 'BuildMachineOSBuild': arch}
        (source / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        artifact = self.root / arch
        artifact.mkdir()
        archive = artifact / f'Nestopia-{arch}.oecoreplugin.zip'
        with zipfile.ZipFile(archive, 'w') as zipped:
            for path in source.rglob('*'):
                if path.is_file():
                    zipped.write(path, path.relative_to(source.parent))
        metadata = {'schema': 1, 'kind': 'core', 'name': 'Nestopia', 'source_repository': REPO, 'source_sha': SHA,
            'configuration': 'Release', 'architecture': arch, 'bundle_identifier': 'org.openemu.Nestopia',
            'bundle_version': '1.2.3', 'bundle_short_version': '1.2.3', 'xcode': 'Xcode fixture',
            'generated_tracked_files_sha256': {}, 'archive': archive.name,
            'archive_sha256': MERGER.digest(archive), 'archive_size': archive.stat().st_size,
            'checks': ['bundle-architecture', 'codesign-deep-strict', 'zip-crc', 'archived-info-plist']}
        (artifact / 'BUILD-INFO.json').write_text(json.dumps(metadata))

    def change_metadata(self, target_architecture, **changes):
        path = self.root / target_architecture / 'BUILD-INFO.json'
        data = json.loads(path.read_text())
        data.update(changes)
        path.write_text(json.dumps(data))

    def test_source_sha_repository_and_architecture_must_match(self):
        for field, value in [('source_sha', 'b' * 40), ('source_repository', 'somewhere/else'), ('architecture', 'x86_64')]:
            with self.subTest(field=field):
                metadata_file = self.root / 'arm64/BUILD-INFO.json'
                before = metadata_file.read_bytes()
                self.change_metadata('arm64', **{field: value})
                with self.assertRaises(ValueError):
                    MERGER.assemble(self.args)
                metadata_file.write_bytes(before)
        self.assertFalse(self.args.output.exists())

    def test_versions_and_xcode_must_match_between_pairs(self):
        for field in ('bundle_identifier', 'bundle_version', 'bundle_short_version', 'xcode', 'generated_tracked_files_sha256'):
            with self.subTest(field=field):
                metadata_file = self.root / 'x86_64/BUILD-INFO.json'
                before = metadata_file.read_bytes()
                self.change_metadata('x86_64', **{field: 'different'})
                with self.assertRaisesRegex(ValueError, 'provenance differs'):
                    MERGER.assemble(self.args)
                metadata_file.write_bytes(before)
        self.assertFalse(self.args.output.exists())

    def test_tampered_zip_is_rejected(self):
        archive = self.root / 'arm64/Nestopia-arm64.oecoreplugin.zip'
        archive.write_bytes(archive.read_bytes() + b'changed')
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            MERGER.assemble(self.args)
        self.assertFalse(self.args.output.exists())

    def test_existing_output_is_never_replaced(self):
        self.args.output.mkdir()
        retained = self.args.output / 'retained'
        retained.write_bytes(b'previous build')
        with self.assertRaisesRegex(ValueError, 'new directory'):
            MERGER.assemble(self.args)
        self.assertEqual(retained.read_bytes(), b'previous build')

    def test_unsafe_zip_paths_symlinks_and_special_files_are_rejected(self):
        for index, (name, kind, content) in enumerate([
            ('../outside', stat.S_IFREG, b'bad'),
            ('/absolute', stat.S_IFREG, b'bad'),
            ('Nestopia.oecoreplugin/escape', stat.S_IFLNK, b'../../outside'),
            ('Nestopia.oecoreplugin/device', stat.S_IFCHR, b'')]):
            archive = self.root / f'unsafe-{index}.zip'
            with zipfile.ZipFile(archive, 'w') as zipped:
                info = zipfile.ZipInfo(name)
                info.external_attr = (kind | 0o644) << 16
                zipped.writestr(info, content)
            with self.assertRaises((ValueError, OSError)):
                MERGER.extract_archive(archive, self.root / f'extract-{index}', 'Nestopia.oecoreplugin')
        self.assertFalse((self.root / 'outside').exists())

    @unittest.skipUnless(shutil.which('lipo'), 'Real lipo verification needs macOS')
    def test_real_lipo_merges_only_matching_slices_and_normalizes_build_metadata(self):
        original_run = subprocess.run

        def run(command, **kwargs):
            if command[0] == 'codesign':
                self.assertEqual(command[1:4], ['--verify', '--deep', '--strict'])
                return subprocess.CompletedProcess(command, 0)
            self.assertEqual(command[0], 'lipo')
            return original_run(command, **kwargs)

        with mock.patch.object(MERGER.subprocess, 'run', side_effect=run):
            MERGER.assemble(self.args)
        bundle = self.args.output / 'Nestopia.oecoreplugin'
        self.assertEqual(MERGER.architectures(bundle / 'Contents/MacOS/Nestopia'), {'arm64', 'x86_64'})
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleVersion'], '1.2.3')
        self.assertNotIn('BuildMachineOSBuild', info)
        self.assertFalse((bundle / 'Contents/_CodeSignature').exists())
        metadata = json.loads((self.args.output / 'BUILD-INFO.json').read_text())
        self.assertFalse(metadata['bundle_signed'])
        self.assertFalse(metadata['ready_to_publish'])
        self.assertEqual(metadata['source_sha'], SHA)

    @unittest.skipUnless(shutil.which('lipo'), 'Real lipo verification needs macOS')
    def test_unexpected_resource_difference_fails_without_output(self):
        arm = self.root / 'source-arm64/Nestopia.oecoreplugin'
        intel = self.root / 'source-x86_64/Nestopia.oecoreplugin'
        (intel / 'Contents/Resources/data.txt').write_text('different')
        with self.assertRaisesRegex(ValueError, 'Non-code resources differ'):
            MERGER.merge_bundle(arm, intel, self.root / 'staging', self.root)
        self.assertFalse(self.args.output.exists())

    @unittest.skipUnless(shutil.which('lipo'), 'Real lipo verification needs macOS')
    def test_runtime_plist_difference_is_not_hidden_as_build_metadata(self):
        arm = self.root / 'source-arm64/Nestopia.oecoreplugin'
        intel = self.root / 'source-x86_64/Nestopia.oecoreplugin'
        info_path = intel / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['LSMinimumSystemVersion'] = '99.0'
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, 'Runtime Info.plist values differ'):
            MERGER.merge_bundle(arm, intel, self.root / 'staging', self.root)

    def test_only_named_architecture_swift_metadata_can_be_unioned(self):
        self.assertTrue(MERGER.is_swift_arch_resource(Path('Modules/SDK.swiftmodule/arm64-apple-macos.swiftdoc'), 'arm64'))
        for path in ('Resources/arm64-data.json', 'Modules/SDK.swiftmodule/arm64-plugin.dylib',
                     'Modules/SDK.swiftmodule/x86_64-apple-macos.swiftmodule'):
            self.assertFalse(MERGER.is_swift_arch_resource(Path(path), 'arm64'))


if __name__ == '__main__':
    unittest.main()
