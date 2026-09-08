#!/usr/bin/env python3
"""Private fixture tests; no real builds, signatures, keys or registrations."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('stage_universal_app', Path(__file__).resolve().parents[1] / 'stage-universal-app.py')
STAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAGE)
IDENTITY = '1234567890ABCDEF1234567890ABCDEF12345678'


def macho(filetype=8):
    return struct.pack('<8I', 0xFEEDFACF, 0x01000007, 3, filetype, 0, 0, 0, 0)


class StagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='reborn-stage-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / 'repository'
        self.root.mkdir()
        (self.root / 'OpenEmu').mkdir()
        (self.root / 'OpenEmu/OpenEmu.entitlements').write_bytes(plistlib.dumps({}))
        self.host = self.base / 'host/OpenEmu.app'
        self.make_bundle(self.host, 'OpenEmu', 'org.openemu.OpenEmu', 2)
        helper = self.host / 'Contents/Frameworks/Helper.app'
        self.make_bundle(helper, 'Helper', 'org.openemu.Helper', 2)
        self.cores = self.base / 'cores'
        self.cores.mkdir()
        for core in STAGE.CORES:
            self.make_bundle(self.cores / f'{core}.oecoreplugin', core, f'org.openemu.{core}')
        self.output = self.base / 'new-private-stage'
        self.args = argparse.Namespace(host=self.host, cores=self.cores, output=self.output,
            signing_identity=IDENTITY, source_sha='a' * 40)
        self.commands = []
        self.fail_architecture = False
        self.fail_signing = False
        self.cdhash_requirement = False
        self.available_identity = True
        self.mutate_input = False
        self.addCleanup(patch.stopall)
        patch.object(STAGE, 'ROOT', self.root).start()
        patch.object(STAGE, 'run', side_effect=self.fake_run).start()

    def make_bundle(self, path, executable, identifier, filetype=8):
        (path / 'Contents/MacOS').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identifier, 'CFBundleExecutable': executable,
            'CFBundleVersion': '23', 'CFBundleShortVersionString': '1.0.0'}))
        binary = path / 'Contents/MacOS' / executable
        binary.write_bytes(macho(filetype))
        binary.chmod(0o755)

    def fake_run(self, command, capture=False):
        command = [str(value) for value in command]
        self.commands.append(command)
        if command[0] == 'security':
            self.assertEqual(command, ['security', 'find-identity', '-v', '-p', 'codesigning'])
            return f'  1) {IDENTITY} "Fixture only"\n' if self.available_identity else '0 valid identities found'
        if command[0] == 'ditto':
            self.assertEqual(len(command), 3)
            shutil.copytree(command[1], command[2], symlinks=True)
            return None
        if command[0] == 'bash':
            self.assertEqual(command[1], str(self.root / 'Scripts/verify-bundle-architectures.sh'))
            self.assertIn(command[3], ('arm64', 'x86_64'))
            if self.fail_architecture:
                raise subprocess.CalledProcessError(1, command)
            return None
        self.assertEqual(command[0], 'codesign', f'Unexpected operation: {command}')
        if '--force' in command:
            target = Path(command[-1])
            self.assertTrue(target.is_relative_to(self.base))
            self.assertTrue(target.relative_to(self.base).parts[0].startswith('.reborn-stage-'))
            self.assertNotIn('--deep', command)
            self.assertEqual(command[command.index('--sign') + 1], IDENTITY)
            if self.fail_signing:
                raise subprocess.CalledProcessError(1, command)
            if self.mutate_input:
                (self.cores / '4DO.oecoreplugin/Contents/Info.plist').write_bytes(b'fixture mutation')
                self.mutate_input = False
        elif '--display' in command:
            return 'designated => cdhash H"1234"' if self.cdhash_requirement else f'designated => identifier "org.openemu.OpenEmu" and certificate leaf = H"{IDENTITY}"'
        else:
            self.assertIn('--verify', command)
        return None

    def invoke(self):
        with contextlib.redirect_stdout(io.StringIO()):
            STAGE.stage(self.args)

    def assert_no_staging_left(self):
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.base.glob('.reborn-stage-*')), [])

    def test_success_signs_only_new_copies_and_never_installs(self):
        before_host = STAGE.fingerprint(self.host)
        before_cores = STAGE.fingerprint(self.cores)
        self.invoke()
        app = self.output / 'OpenEmu.app'
        report = json.loads((self.output / 'STAGING-INFO.json').read_text())
        self.assertEqual(len(list((app / 'Contents/PlugIns/Cores').iterdir())), 28)
        self.assertEqual(report['certificate_sha1'], IDENTITY)
        self.assertEqual(report['architecture'], 'universal')
        self.assertFalse(report['registration_requested'])
        self.assertFalse(report['ready_to_publish'])
        self.assertEqual(report['output_bundle_fingerprint'], STAGE.fingerprint(app))
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o700)
        self.assertEqual(STAGE.fingerprint(self.host), before_host)
        self.assertEqual(STAGE.fingerprint(self.cores), before_cores)
        signs = [command for command in self.commands if '--force' in command]
        self.assertEqual(len(signs), 57)  # 28 core executables + 28 bundles + host seal
        self.assertFalse(any('Helper.app' in command[-1] for command in signs))
        self.assertEqual({command[3] for command in self.commands if command[0] == 'bash'}, {'arm64', 'x86_64'})
        self.assertFalse((self.root / 'OpenEmu-Intel-test').exists())

    def test_rejects_ad_hoc_or_missing_identity_without_signing(self):
        for identity in ('-', 'Name not a fingerprint', '0' * 39):
            with self.subTest(identity=identity):
                self.args.signing_identity = identity
                with self.assertRaisesRegex(ValueError, 'exact 40-hex'):
                    self.invoke()
        self.assertEqual(self.commands, [])
        self.args.signing_identity = IDENTITY
        self.available_identity = False
        with self.assertRaisesRegex(ValueError, 'identity is unavailable'):
            self.invoke()
        self.assertFalse(any('--force' in command for command in self.commands))
        self.assert_no_staging_left()

    def test_rejects_incomplete_or_extra_core_set(self):
        core = self.cores / '4DO.oecoreplugin'
        core.rename(self.cores / 'unexpected.oecoreplugin')
        with self.assertRaisesRegex(ValueError, 'exactly the 28'):
            self.invoke()
        self.assertEqual(self.commands, [])

    def test_rejects_host_with_old_bundled_cores(self):
        old = self.host / 'Contents/PlugIns/Cores/Old.oecoreplugin'
        old.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, 'already contains cores'):
            self.invoke()
        self.assertEqual(self.commands, [])

    def test_architecture_failure_precedes_signing(self):
        self.fail_architecture = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        self.assertFalse(any('--force' in command for command in self.commands))
        self.assert_no_staging_left()

    def test_signing_failure_leaves_inputs_and_canonical_untouched(self):
        before_host = STAGE.fingerprint(self.host)
        before_cores = STAGE.fingerprint(self.cores)
        self.fail_signing = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        self.assertEqual(STAGE.fingerprint(self.host), before_host)
        self.assertEqual(STAGE.fingerprint(self.cores), before_cores)
        self.assert_no_staging_left()

    def test_unstable_requirement_or_concurrent_mutation_cannot_publish(self):
        self.cdhash_requirement = True
        with self.assertRaisesRegex(ValueError, 'stable certificate'):
            self.invoke()
        self.assert_no_staging_left()
        self.cdhash_requirement = False
        self.mutate_input = True
        with self.assertRaisesRegex(ValueError, 'Input changed during staging'):
            self.invoke()
        self.assert_no_staging_left()

    def test_existing_or_canonical_output_is_never_replaced(self):
        self.output.mkdir()
        marker = self.output / 'keep'
        marker.write_text('untouched')
        with self.assertRaisesRegex(ValueError, 'new absolute staging'):
            self.invoke()
        self.assertEqual(marker.read_text(), 'untouched')
        for output in (self.root / 'OpenEmu-Intel-test', self.root / 'OpenEmu-Intel-test/nested'):
            with self.subTest(output=output):
                self.args.output = output
                with self.assertRaisesRegex(ValueError, 'new absolute staging'):
                    self.invoke()
        self.assertEqual(self.commands, [])

    def test_external_symlinks_and_user_data_inputs_are_rejected(self):
        link = self.host / 'Contents/escape'
        link.symlink_to(self.cores)
        with self.assertRaisesRegex(ValueError, 'symlink escapes'):
            self.invoke()
        link.unlink()
        (self.host.parent / '.openemu-data-folder.plist').write_text('fixture')
        with self.assertRaisesRegex(ValueError, 'selected OpenEmu data folder'):
            self.invoke()
        self.assertEqual(self.commands, [])

    def test_header_reader_distinguishes_code_from_archives(self):
        path = self.base / 'header-fixture'
        path.write_bytes(macho(2))
        self.assertEqual(STAGE.macho_filetypes(path), {2})
        path.write_bytes(b'!<arch>\n')
        self.assertEqual(STAGE.macho_filetypes(path), set())
        header = struct.pack('>2I', 0xCAFEBABE, 2)
        header += struct.pack('>5I', 0x01000007, 3, 48, 32, 0)
        header += struct.pack('>5I', 0x0100000C, 0, 80, 32, 0)
        path.write_bytes(header + macho(6) + macho(8))
        self.assertEqual(STAGE.macho_filetypes(path), {6, 8})


class CommandCaptureTests(unittest.TestCase):
    def test_requirements_capture_includes_codesign_stderr(self):
        with patch.object(STAGE.subprocess, 'run', return_value=argparse.Namespace(stdout='designated => fixture')) as native:
            self.assertEqual(STAGE.run(['codesign', '--display'], capture=True), 'designated => fixture')
        self.assertEqual(native.call_args.kwargs['stderr'], subprocess.STDOUT)
        self.assertEqual(native.call_args.kwargs['stdout'], subprocess.PIPE)


if __name__ == '__main__':
    unittest.main()
