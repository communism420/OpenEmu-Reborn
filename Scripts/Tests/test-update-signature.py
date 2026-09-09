#!/usr/bin/env python3
"""Test the real public-key verifier using RFC 8032 public test vectors only.

No private key generation, signing, Keychain access or release downloads.
"""
import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPOSITORY = Path(__file__).resolve().parents[2]
# RFC 8032 section 7.1, TEST 2 (https://www.rfc-editor.org/rfc/rfc8032#section-7.1).
PUBLIC_KEY = bytes.fromhex('3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c')
SIGNATURE = bytes.fromhex('92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
                          '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00')


class PublicSignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='reborn-public-signature-')
        cls.root = Path(cls.directory.name)
        cls.archive = cls.root / 'fixture.data'
        cls.environment = os.environ.copy()
        cls.environment.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def verify(self, message=b'r', key=PUBLIC_KEY, signature=SIGNATURE):
        self.archive.write_bytes(message)
        return subprocess.run(['swift', '-module-cache-path', str(self.root / 'module-cache'),
            str(REPOSITORY / 'Scripts/verify-update-signature.swift'), str(self.archive),
            base64.b64encode(key).decode(), base64.b64encode(signature).decode()],
            env=self.environment, capture_output=True, text=True, timeout=60)

    def test_valid_public_vector(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_changed_archive_fails(self):
        self.assertNotEqual(self.verify(message=b's').returncode, 0)

    def test_different_public_key_fails(self):
        self.assertNotEqual(self.verify(key=bytes(32)).returncode, 0)

    def test_changed_signature_fails(self):
        self.assertNotEqual(self.verify(signature=bytes(64)).returncode, 0)

    def test_truncated_key_and_signature_fail(self):
        self.assertNotEqual(self.verify(key=PUBLIC_KEY[:-1]).returncode, 0)
        self.assertNotEqual(self.verify(signature=SIGNATURE[:-1]).returncode, 0)


if __name__ == '__main__':
    unittest.main()
