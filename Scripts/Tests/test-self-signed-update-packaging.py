#!/usr/bin/env python3
"""Run the real packaging script with synthetic bundles and mocked signing tools.

No private keys, user app, installed cores, releases, Git or network are touched.
"""
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

REPOSITORY = Path(__file__).resolve().parents[2]
CORE_NAMES = ('4DO Atari800 Bliss BSNES CrabEmu DeSmuME Dolphin FCEU Flycast Gambatte '
              'GenesisPlus JollyCV MAME Mednafen mGBA Mupen64Plus Nestopia O2EM Picodrive '
              'PokeMini Potator PPSSPP ProSystem SNES9x Stella VecXGL VirtualJaguar blueMSX').split()
KEY = base64.b64encode(bytes(range(32))).decode()
SIGNATURE = base64.b64encode(bytes(range(64))).decode()
MOCK = '''#!/usr/bin/env python3
import json, os, pathlib, plistlib, sys, zipfile
command = pathlib.Path(sys.argv[0]).name
with open(os.environ['MOCK_CALLS'], 'a') as stream:
    stream.write(json.dumps([command] + sys.argv[1:]) + '\\n')
if command == 'codesign':
    if os.environ.get('FAIL_CERTIFICATE') and '--test-requirement' in sys.argv: sys.exit(1)
    if os.environ.get('FAIL_ARCHIVE_CERTIFICATE') and '--test-requirement' in sys.argv and 'reborn-update-inspect-' in sys.argv[-1]: sys.exit(1)
    if '--display' in sys.argv: print('designated => identifier "org.openemu.OpenEmu" and certificate leaf = H"' + 'A'*40 + '"')
elif command == 'lipo':
    archived = any('reborn-update-inspect-' in item for item in sys.argv)
    if '-archs' in sys.argv:
        if pathlib.Path(sys.argv[-1]).name != 'OpenEmu': sys.exit(1)
        print('arm64 x86_64')
    elif os.environ.get('FAIL_ARCH') == sys.argv[-1]: sys.exit(1)
    elif archived and os.environ.get('ARCHIVE_ONLY_ARM64') and sys.argv[-1] == 'x86_64': sys.exit(1)
elif command == 'swift':
    if os.environ.get('FAIL_EDDSA'): sys.exit(1)
elif command == 'sign_update':
    print('sparkle:edSignature="' + os.environ['MOCK_SIGNATURE'] + '" length="1"')
elif command == 'ditto':
    bundle = pathlib.Path(sys.argv[-2])
    with zipfile.ZipFile(sys.argv[-1], 'w') as archive:
        for path in bundle.rglob('*'):
            relative = path.relative_to(bundle.parent)
            if relative.as_posix() == 'OpenEmu.app/Contents/Info.plist':
                info = plistlib.loads(path.read_bytes())
                if os.environ.get('ARCHIVE_BUILD'): info['CFBundleVersion'] = os.environ['ARCHIVE_BUILD']
                if os.environ.get('ARCHIVE_PUBLIC_KEY'): info['SUPublicEDKey'] = os.environ['ARCHIVE_PUBLIC_KEY']
                archive.writestr(zipfile.ZipInfo.from_file(path, relative), plistlib.dumps(info))
            else: archive.write(path, relative)
        if os.environ.get('ARCHIVE_SECOND_APP'):
            archive.writestr('Other.app/Contents/Info.plist', b'not a permitted second app')
else:
    print('Forbidden external/build command in private packaging test: ' + command, file=sys.stderr)
    sys.exit(98)
'''


class SelfSignedPackagingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='reborn-self-signed-fixture-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'Scripts').mkdir()
        for name in ('release.sh', 'prepare-self-signed-update.sh', 'update_appcast.py',
                     'update_archive.py', 'verify-update-signature.swift', 'verify-bundle-architectures.sh'):
            shutil.copyfile(REPOSITORY / 'Scripts' / name, self.root / 'Scripts' / name)
        self.app = self.root / 'OpenEmu.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/MacOS/OpenEmu').write_bytes(b'synthetic, never executable')
        for core in CORE_NAMES:
            (self.app / f'Contents/PlugIns/Cores/{core}.oecoreplugin').mkdir(parents=True)
        self.plist = {
            'CFBundleIdentifier': 'org.openemu.OpenEmu', 'CFBundleShortVersionString': '1.0.0',
            'CFBundleVersion': '23', 'SUPublicEDKey': KEY,
            'SUFeedURL': 'https://raw.githubusercontent.com/communism420/OpenEmu-Reborn/main/appcast.xml'}
        (self.root / 'OpenEmu').mkdir()
        self.write_plist()
        self.notes = self.root / 'notes.md'
        self.notes.write_text('## Fixture\n- Verified test update\n')
        (self.root / 'appcast.xml').write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><language>en</language><item><enclosure sparkle:version="21"/></item></channel></rss>')
        mock_bin = self.root / 'mock-bin'
        mock_bin.mkdir()
        for name in ('codesign', 'lipo', 'swift', 'sign_update', 'ditto', 'security', 'xcodebuild', 'gh', 'xcrun'):
            executable = mock_bin / name
            executable.write_text(MOCK)
            executable.chmod(0o755)
        self.calls = self.root / 'calls.jsonl'
        self.env = {**os.environ, 'PATH': f'{mock_bin}:{os.environ["PATH"]}',
                    'MOCK_CALLS': str(self.calls), 'MOCK_SIGNATURE': SIGNATURE,
                    'OPENEMU_SIGN_UPDATE': str(mock_bin / 'sign_update'), 'PYTHONDONTWRITEBYTECODE': '1'}
        for variable in ('OPENEMU_RELEASE_REPO', 'OPENEMU_SPARKLE_ACCOUNT', 'FAIL_CERTIFICATE', 'FAIL_ARCH', 'FAIL_EDDSA',
                         'ARCHIVE_BUILD', 'ARCHIVE_PUBLIC_KEY', 'ARCHIVE_ONLY_ARM64', 'ARCHIVE_SECOND_APP', 'FAIL_ARCHIVE_CERTIFICATE'):
            self.env.pop(variable, None)
        self.output = self.root / 'prepared'

    def write_plist(self):
        encoded = plistlib.dumps(self.plist)
        (self.app / 'Contents/Info.plist').write_bytes(encoded)
        (self.root / 'OpenEmu/OpenEmu-Info.plist').write_bytes(encoded)

    def run_script(self, arch='universal', identity='A'*40):
        return subprocess.run(['bash', str(self.root / 'Scripts/release.sh'), '--self-signed', '1.0.0', str(self.notes),
            '--app', str(self.app), '--arch', arch, '--signing-identity', identity, '--output', str(self.output)],
            env=self.env, capture_output=True, text=True, timeout=45)

    def test_prepared_zip_keeps_original_app_and_does_not_advertise(self):
        old_plist = (self.app / 'Contents/Info.plist').read_bytes()
        old_feed = (self.root / 'appcast.xml').read_bytes()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = json.loads((self.output / 'prepared-update-v1.0.0-universal.json').read_text())
        self.assertEqual(manifest['build'], '23')
        self.assertEqual(manifest['public_key'], KEY)
        self.assertEqual(manifest['architecture'], 'universal')
        self.assertEqual((self.app / 'Contents/Info.plist').read_bytes(), old_plist)
        self.assertEqual((self.root / 'appcast.xml').read_bytes(), old_feed)
        self.assertTrue((self.output / 'OpenEmu-Reborn-universal.zip').is_file())
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertTrue(any(call[0] == 'sign_update' and call[1:3] == ['--account', 'org.openemu.Reborn.updates'] for call in calls))
        self.assertFalse(any(call[0] in ('security', 'xcodebuild', 'gh', 'xcrun') for call in calls))
        self.assertFalse(any('--force' in call for call in calls))

    def test_wrong_certificate_fails_before_archiving_or_signing(self):
        self.env['FAIL_CERTIFICATE'] = '1'
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertNotIn('sign_update', self.calls.read_text())

    def test_missing_cpu_slice_fails_before_archiving_or_signing(self):
        self.env['FAIL_ARCH'] = 'arm64'
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertNotIn('sign_update', self.calls.read_text())

    def test_bad_eddsa_signature_creates_no_publishable_manifest(self):
        self.env['FAIL_EDDSA'] = '1'
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.output / 'prepared-update-v1.0.0-universal.json').exists())

    def test_valid_signature_does_not_allow_different_archived_app_metadata(self):
        for variable, value in [('ARCHIVE_BUILD', '22'), ('ARCHIVE_PUBLIC_KEY', base64.b64encode(bytes(32)).decode()),
                                ('ARCHIVE_ONLY_ARM64', '1'), ('ARCHIVE_SECOND_APP', '1'), ('FAIL_ARCHIVE_CERTIFICATE', '1')]:
            with self.subTest(variable=variable):
                self.output = self.root / ('prepared-' + variable)
                self.env[variable] = value
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse((self.output / 'prepared-update-v1.0.0-universal.json').exists())
                self.env.pop(variable)

    def test_inherited_key_is_rejected_before_signing(self):
        self.plist['SUPublicEDKey'] = 'wVICc/NGoDFzkEbDb63QMFpKlRs14e/WhIiwIngQGsg='
        self.write_plist()
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertFalse(self.output.exists())

    def test_ambiguous_or_adhoc_identity_and_thin_intel_shared_feed_are_rejected(self):
        for identity in ('-', 'OpenEmu Local Signing', ''):
            self.assertNotEqual(self.run_script(identity=identity).returncode, 0)
        self.assertNotEqual(self.run_script(arch='x86_64').returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
