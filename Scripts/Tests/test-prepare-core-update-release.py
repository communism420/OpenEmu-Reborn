#!/usr/bin/env python3
"""Private core-publication fixtures. No actual key, binary build, or publication."""

import argparse
import base64
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile


SPEC = importlib.util.spec_from_file_location(
    "prepare_core_release", Path(__file__).resolve().parents[1] / "prepare-core-update-release.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SOURCE_SHA = "a" * 40
PUBLIC_KEY = base64.b64encode(bytes(32)).decode()
SIGNATURE = base64.b64encode(bytes(64)).decode()


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="openemu-core-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir()
        self.catalog = ET.parse(MODULE.ROOT / "oecores.xml").getroot()
        self.signer = self.root / "fixture-sign-tool"
        self.signer.write_text("fixture only; never executed\n")
        self.signer.chmod(0o755)
        self.args = argparse.Namespace(artifacts_dir=self.artifacts, source_sha=SOURCE_SHA,
                                       tag="cores-reborn-v1.0.0", public_key=PUBLIC_KEY,
                                       sign_tool=self.signer, account="org.openemu.Reborn.updates",
                                       output=self.root / "prepared")
        self.calls = []

    def artifact(self, core="Nestopia", arch="arm64", extra=None):
        directory = self.artifacts / f"reborn-core-{core}-{arch}"
        directory.mkdir()
        archive = directory / f"{core}-{arch}.oecoreplugin.zip"
        info = {"CFBundleIdentifier": f"org.openemu.{core}", "CFBundleVersion": "1.2.3",
                "CFBundleExecutable": core, "LSMinimumSystemVersion": "11.0",
                "SUFeedURL": "https://example.invalid/preserved-embedded-feed.xml"}
        with zipfile.ZipFile(archive, "w") as zipped:
            zipped.writestr(f"{core}.oecoreplugin/Contents/Info.plist", plistlib.dumps(info))
            zipped.writestr(f"{core}.oecoreplugin/Contents/MacOS/{core}", f"fixture-{arch}".encode())
            if extra:
                for path, value in extra:
                    zipped.writestr(path, value)
        metadata = {"schema": 1, "kind": "core", "name": core, "architecture": arch,
                    "source_sha": SOURCE_SHA, "source_repository": MODULE.REPOSITORY,
                    "configuration": "Release", "archive": archive.name, "archive_signed": False,
                    "workflow_run_id": "123", "workflow_run_attempt": "1",
                    "bundle_identifier": info["CFBundleIdentifier"], "bundle_version": "1.2.3",
                    "generated_tracked_files_sha256": {}, "archive_size": archive.stat().st_size,
                    "archive_sha256": MODULE.digest(archive),
                    "checks": ["bundle-architecture", "codesign-deep-strict", "zip-crc", "archived-info-plist"]}
        (directory / "BUILD-INFO.json").write_text(json.dumps(metadata))
        return archive, metadata

    def all_artifacts(self):
        return [self.artifact(core, arch) for core in MODULE.CORES for arch in MODULE.ARCHITECTURES]

    def fixture_tool(self, command, **kwargs):
        self.calls.append(command)
        if str(command[0]) == str(self.signer):
            self.assertEqual(command[1:3], ["--account", "org.openemu.Reborn.updates"])
            self.assertTrue(Path(command[-1]).resolve().is_relative_to(self.artifacts.resolve()))
            return subprocess.CompletedProcess(command, 0,
                stdout=f'sparkle:edSignature="{SIGNATURE}" length="{Path(command[-1]).stat().st_size}"', stderr="")
        self.assertIn(str(command[0]), ("bash", "codesign", "xcrun")
                      if Path(command[0]).name != "verify-update-signature" else (str(command[0]),))
        return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

    def prepare(self):
        with patch.object(MODULE, "read_catalog", return_value=copy.deepcopy(self.catalog)), \
             patch.object(MODULE, "source_public_key", return_value=PUBLIC_KEY), \
             patch.object(MODULE.subprocess, "run", side_effect=self.fixture_tool):
            MODULE.prepare(self.args)

    def test_missing_one_architecture_fails_before_signing(self):
        self.artifact()
        with self.assertRaisesRegex(ValueError, "complete 56-artifact set"):
            self.prepare()
        self.assertEqual(self.calls, [])
        self.assertFalse(self.args.output.exists())

    def test_wrong_source_revision_rejected(self):
        archive, _ = self.artifact()
        with self.assertRaisesRegex(ValueError, "incorrect source_sha"):
            MODULE.validate_metadata(archive.parent, "Nestopia", "arm64", "b" * 40)

    def test_valid_length_wrong_key_rejected_before_any_signing(self):
        self.args.public_key = base64.b64encode(bytes([1]) * 32).decode()
        with patch.object(MODULE.subprocess, "check_output", return_value=plistlib.dumps({"SUPublicEDKey": PUBLIC_KEY})) as reader, \
             patch.object(MODULE.subprocess, "run", side_effect=self.fixture_tool):
            with self.assertRaisesRegex(ValueError, "SUPublicEDKey in the exact source revision"):
                MODULE.prepare(self.args)
        reader.assert_called_once_with(["git", "show", f"{SOURCE_SHA}:OpenEmu/OpenEmu-Info.plist"], cwd=MODULE.ROOT)
        self.assertEqual(self.calls, [])
        self.assertFalse(self.args.output.exists())

    def test_oversized_metadata_rejected_before_any_signing(self):
        originals = self.all_artifacts()
        archive, metadata = originals[0]
        metadata["archive_size"] = MODULE.MAXIMUM_ARCHIVE_LENGTH + 1
        (archive.parent / "BUILD-INFO.json").write_text(json.dumps(metadata))
        with self.assertRaisesRegex(ValueError, "runtime 1 GiB limit"):
            self.prepare()
        self.assertEqual(self.calls, [])
        self.assertFalse(self.args.output.exists())

    def test_actual_compressed_archive_cannot_exceed_runtime_limit(self):
        archive, _ = self.artifact()
        # A sparse private fixture exercises the stat guard without writing 1 GiB.
        with archive.open("r+b") as stream:
            stream.truncate(MODULE.MAXIMUM_ARCHIVE_LENGTH + 1)
        with self.assertRaisesRegex(ValueError, "runtime 1 GiB limit"):
            MODULE.validate_metadata(archive.parent, "Nestopia", "arm64", SOURCE_SHA)

    def test_tampered_archive_rejected(self):
        archive, _ = self.artifact()
        with archive.open("ab") as stream:
            stream.write(b"tampered")
        with self.assertRaisesRegex(ValueError, "size differs"):
            MODULE.validate_metadata(archive.parent, "Nestopia", "arm64", SOURCE_SHA)

    def test_zip_traversal_rejected_without_outside_write(self):
        archive, metadata = self.artifact(extra=[("Nestopia.oecoreplugin/../../outside", b"bad")])
        destination = self.root / "extracted"
        destination.mkdir()
        with self.assertRaisesRegex(ValueError, "unsafe ZIP path"):
            MODULE.verify_archive(archive, metadata, destination)
        self.assertFalse((self.root / "outside").exists())

    def test_zip_case_collision_rejected(self):
        archive, _ = self.artifact(extra=[("Nestopia.oecoreplugin/Contents/info.plist", b"bad")])
        with self.assertRaisesRegex(ValueError, "duplicate ZIP path"):
            MODULE.safe_extract(archive, self.root / "extracted", "Nestopia.oecoreplugin")

    def test_escaping_symlink_rejected(self):
        link = zipfile.ZipInfo("Nestopia.oecoreplugin/Contents/escape")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive, _ = self.artifact(extra=[(link, b"../../../outside")])
        with self.assertRaisesRegex(ValueError, "symlink target leaves"):
            MODULE.safe_extract(archive, self.root / "extracted", "Nestopia.oecoreplugin")

    def test_valid_framework_style_symlink_preserved(self):
        link = zipfile.ZipInfo("Nestopia.oecoreplugin/Contents/Resources")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive, _ = self.artifact(extra=[("Nestopia.oecoreplugin/Contents/Versions/A/value", b"retained"),
                                         (link, b"Versions/A")])
        bundle = MODULE.safe_extract(archive, self.root / "extracted", "Nestopia.oecoreplugin")
        self.assertTrue((bundle / "Contents/Resources").is_symlink())
        self.assertEqual((bundle / "Contents/Resources/value").read_bytes(), b"retained")

    def test_archive_cannot_write_beneath_symlink(self):
        link = zipfile.ZipInfo("Nestopia.oecoreplugin/Contents/Resources")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive, _ = self.artifact(extra=[(link, b"Versions/A"),
                                         ("Nestopia.oecoreplugin/Contents/Resources/value", b"bad")])
        with self.assertRaisesRegex(ValueError, "writes beneath a symlink"):
            MODULE.safe_extract(archive, self.root / "extracted", "Nestopia.oecoreplugin")

    def test_cyclic_symlink_rejected(self):
        link = zipfile.ZipInfo("Nestopia.oecoreplugin/Contents/Resources")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive, _ = self.artifact(extra=[(link, b"Resources")])
        with self.assertRaisesRegex(ValueError, "cyclic archive symlink"):
            MODULE.safe_extract(archive, self.root / "extracted", "Nestopia.oecoreplugin")

    def test_architecture_verifier_failure_is_not_ignored(self):
        archive, metadata = self.artifact()
        with patch.object(MODULE.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "architecture")):
            with self.assertRaises(subprocess.CalledProcessError):
                MODULE.verify_archive(archive, metadata, self.root / "extracted")

    def test_bundle_version_must_match_metadata(self):
        archive, metadata = self.artifact()
        metadata["bundle_version"] = "9.9.9"
        with self.assertRaisesRegex(ValueError, "bundle version mismatch"):
            MODULE.verify_archive(archive, metadata, self.root / "extracted")

    def test_wrong_signature_verification_aborts_output(self):
        originals = self.all_artifacts()
        normal_tool = self.fixture_tool

        def reject_signature(command, **kwargs):
            if Path(command[0]).name == "verify-update-signature":
                raise subprocess.CalledProcessError(1, "invalid archive signature")
            return normal_tool(command, **kwargs)

        with patch.object(MODULE, "read_catalog", return_value=copy.deepcopy(self.catalog)), \
             patch.object(MODULE, "source_public_key", return_value=PUBLIC_KEY), \
             patch.object(MODULE.subprocess, "run", side_effect=reject_signature):
            with self.assertRaises(subprocess.CalledProcessError):
                MODULE.prepare(self.args)
        self.assertFalse(self.args.output.exists())
        self.assertEqual(sum(str(call[0]) == str(self.signer) for call in self.calls), 1)
        self.assertEqual(MODULE.digest(originals[0][0]), originals[0][1]["archive_sha256"])

    def test_complete_catalog_has_exact_56_assets_and_preserved_original_bytes(self):
        originals = self.all_artifacts()
        self.prepare()
        manifest = json.loads((self.args.output / "release-manifest.json").read_text())
        self.assertEqual(len(manifest["cores"]), 56)
        self.assertFalse(manifest["published"])
        self.assertEqual(sum(str(call[0]) == str(self.signer) for call in self.calls), 56)
        for archive, metadata in originals:
            self.assertEqual(MODULE.digest(archive), metadata["archive_sha256"])
            copied = self.args.output / "assets" / archive.name
            self.assertEqual(hashlib.sha256(copied.read_bytes()).hexdigest(), metadata["archive_sha256"])
        for arch in MODULE.ARCHITECTURES:
            directory = self.args.output / "Updates/cores" / arch
            catalog = ET.parse(directory / "oecores.xml").getroot()
            self.assertEqual(catalog.get("architecture"), arch)
            self.assertEqual(catalog.get("schema"), "1")
            self.assertEqual(len(catalog.findall("core")), 28)
            for entry in catalog.findall("core"):
                self.assertIn(f"/Updates/cores/{arch}/", entry.get("appcastURL"))
            for core in MODULE.CORES:
                item = ET.parse(directory / f"{core.lower()}.xml").find("./channel/item")
                enclosure = item.find("enclosure")
                self.assertEqual(item.findtext(f"{{{MODULE.SPARKLE}}}hardwareRequirements"), arch)
                self.assertEqual(enclosure.get(f"{{{MODULE.SPARKLE}}}edSignature"), SIGNATURE)
                self.assertEqual(enclosure.get("url"),
                    f"https://github.com/{MODULE.REPOSITORY}/releases/download/cores-reborn-v1.0.0/{core}-{arch}.oecoreplugin.zip")


if __name__ == "__main__":
    unittest.main()
