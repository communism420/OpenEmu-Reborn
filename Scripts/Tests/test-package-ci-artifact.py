#!/usr/bin/env python3
"""Check artifact source attribution and archive metadata in private fixtures."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SPEC = importlib.util.spec_from_file_location(
    "package_ci_artifact", Path(__file__).resolve().parents[1] / "package-ci-artifact.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="openemu-ci-artifact-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "checkout"
        self.repo.mkdir()
        self.run_git("init", "-q")
        (self.repo / "source.txt").write_text("fixture source\n")
        header = self.repo / "DeSmuME/src/scmrev.h"
        header.parent.mkdir(parents=True)
        header.write_text("fixture revision\n")
        self.run_git("add", ".")
        self.run_git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                     "commit", "-qm", "fixture")
        self.revision = self.run_git("rev-parse", "HEAD").strip()
        self.root_patch = patch.object(MODULE, "ROOT", self.repo)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)

        self.bundle = self.root / "Build/Products/Release/Nestopia.oecoreplugin"
        (self.bundle / "Contents/MacOS").mkdir(parents=True)
        (self.bundle / "Contents/MacOS/Nestopia").write_bytes(b"synthetic executable")
        self.info = {"CFBundleIdentifier": "org.openemu.Nestopia", "CFBundleVersion": "1.2.3",
                     "CFBundleExecutable": "Nestopia"}
        (self.bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        self.args = argparse.Namespace(kind="core", name="Nestopia", arch="arm64",
                                       bundle=self.bundle, source_sha=self.revision,
                                       output=self.root / "artifact")

    def run_git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True)

    def make_host_fixture(self):
        host = self.bundle.with_name("OpenEmu.app")
        self.bundle.rename(host)
        self.bundle = host
        self.args.bundle = host
        self.args.kind = "host"
        self.args.name = "OpenEmu"
        (host / "Contents/MacOS/Nestopia").rename(host / "Contents/MacOS/OpenEmu")
        self.info.update(CFBundleIdentifier="org.openemu.OpenEmu", CFBundleExecutable="OpenEmu")
        (host / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

    def test_rejects_different_source_revision(self):
        with self.assertRaisesRegex(ValueError, "exact checked-out commit"):
            MODULE.source_metadata("f" * 40, "core", "Nestopia")

    def test_rejects_uncommitted_source(self):
        (self.repo / "source.txt").write_text("uncommitted change\n")
        with self.assertRaisesRegex(ValueError, "unexpected tracked source changes"):
            MODULE.source_metadata(self.revision, "core", "Nestopia")

    def test_records_generated_desmume_revision_without_attributing_it_to_commit(self):
        header = self.repo / "DeSmuME/src/scmrev.h"
        header.write_text("generated revision\n")
        revision, generated = MODULE.source_metadata(self.revision, "core", "DeSmuME")
        self.assertEqual(revision, self.revision)
        self.assertEqual(generated, {"DeSmuME/src/scmrev.h": hashlib.sha256(header.read_bytes()).hexdigest()})
        with self.assertRaisesRegex(ValueError, "unexpected tracked source changes"):
            MODULE.source_metadata(self.revision, "host", "OpenEmu")

    def test_rejects_other_bundle(self):
        self.args.name = "Stella"
        with self.assertRaisesRegex(ValueError, "bundle name"):
            MODULE.package(self.args)

    def test_rejects_output_inside_input_bundle(self):
        self.args.output = self.bundle / "artifact"
        with self.assertRaisesRegex(ValueError, "outside the input bundle"):
            MODULE.package(self.args)

    def test_refuses_to_overwrite_previous_artifact(self):
        self.args.output.mkdir()
        retained = self.args.output / "retained.txt"
        retained.write_text("previous output")
        with self.assertRaisesRegex(ValueError, "new directory"):
            MODULE.package(self.args)
        self.assertEqual(retained.read_text(), "previous output")

    def test_rejects_architecture_failure_before_creating_output(self):
        original_run = subprocess.run

        def reject_architecture(command, **kwargs):
            if command[0] == "git":
                return original_run(command, **kwargs)
            raise subprocess.CalledProcessError(1, "architecture")

        with patch.object(MODULE.subprocess, "run", side_effect=reject_architecture):
            with self.assertRaises(subprocess.CalledProcessError):
                MODULE.package(self.args)
        self.assertFalse(self.args.output.exists())

    def test_rejects_universal_core_before_reading_source_or_creating_output(self):
        self.args.arch = "universal"
        with patch.object(MODULE, "source_metadata") as source:
            with self.assertRaisesRegex(ValueError, "only for the host app"):
                MODULE.package(self.args)
        source.assert_not_called()
        self.assertFalse(self.args.output.exists())

    def test_universal_host_rejects_missing_second_cpu_before_creating_output(self):
        self.make_host_fixture()
        self.args.arch = "universal"
        original_run = subprocess.run
        checked = []

        def reject_intel(command, **kwargs):
            if command[0] == "git":
                return original_run(command, **kwargs)
            if not command[0].endswith("verify-bundle-architectures.sh"):
                self.fail(f"unexpected tool before rejecting missing CPU: {command}")
            checked.append(command[2])
            if command[2] == "x86_64":
                raise subprocess.CalledProcessError(1, "missing x86_64")

        with patch.object(MODULE.subprocess, "run", side_effect=reject_intel):
            with self.assertRaises(subprocess.CalledProcessError):
                MODULE.package(self.args)
        self.assertEqual(checked, ["arm64", "x86_64"])
        self.assertFalse(self.args.output.exists())

    def test_universal_host_checks_both_cpus_and_preserves_source_metadata(self):
        self.make_host_fixture()
        self.args.arch = "universal"
        original_output = MODULE.output
        original_run = subprocess.run
        calls = []

        def fake_output(*command):
            return "Xcode fixture" if command[0] == "xcodebuild" else original_output(*command)

        def fixture_tool(command, **kwargs):
            if command[0] == "git":
                return original_run(command, **kwargs)
            calls.append(command)
            if command[0] == "ditto":
                with zipfile.ZipFile(command[-1], "w") as archive:
                    for path in self.bundle.rglob("*"):
                        if path.is_file():
                            archive.write(path, path.relative_to(self.bundle.parent))
            elif command[0] != "codesign" and not command[0].endswith("verify-bundle-architectures.sh"):
                self.fail(f"unexpected tool {command}")

        with patch.object(MODULE, "output", side_effect=fake_output), \
             patch.object(MODULE.subprocess, "run", side_effect=fixture_tool), \
             patch.dict(MODULE.os.environ, {"GITHUB_REPOSITORY": "fixture/repo", "GITHUB_RUN_ID": "123",
                                           "GITHUB_RUN_ATTEMPT": "2"}):
            MODULE.package(self.args)
        self.assertEqual([call[2] for call in calls if call[0].endswith("verify-bundle-architectures.sh")],
                         ["arm64", "x86_64"])
        self.assertIn(["codesign", "--verify", "--deep", "--strict", str(self.bundle.resolve())], calls)
        self.assertEqual(calls[-1][0], "ditto", "verification must precede archive creation")
        metadata = json.loads((self.args.output / "BUILD-INFO.json").read_text())
        archive = self.args.output / metadata["archive"]
        self.assertEqual(metadata["archive"], "OpenEmu-universal.app.zip")
        self.assertEqual(metadata["architecture"], "universal")
        self.assertEqual(metadata["kind"], "host")
        self.assertEqual(metadata["source_sha"], self.revision)
        self.assertEqual(metadata["source_repository"], "fixture/repo")
        self.assertEqual(metadata["workflow_run_id"], "123")
        self.assertEqual(metadata["workflow_run_attempt"], "2")
        self.assertEqual(metadata["archive_sha256"], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertEqual(metadata["archive_size"], archive.stat().st_size)
        self.assertFalse(metadata["archive_signed"])
        with zipfile.ZipFile(archive) as zipped:
            self.assertEqual(zipped.read("OpenEmu.app/Contents/MacOS/OpenEmu"), b"synthetic executable")

    def test_ci_preserves_thin_host_before_building_universal_host_only_on_arm(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/build-check.yml").read_text()
        thin_upload = workflow.index("- name: Preserve verified Release host (${{ matrix.arch }})")
        universal_build = workflow.index("- name: Build universal Release host (no emulator cores)")
        self.assertLess(thin_upload, universal_build)
        universal = workflow[universal_build:]
        self.assertEqual(universal.count("if: matrix.arch == 'arm64'"), 3)
        self.assertIn("-scheme OpenEmu \\", universal)
        self.assertIn("ARCHS='arm64 x86_64'", universal)
        self.assertIn("ONLY_ACTIVE_ARCH=NO", universal)
        self.assertIn('-derivedDataPath "$RUNNER_TEMP/OpenEmuDerivedData"', universal)
        self.assertIn("for architecture in arm64 x86_64; do", universal)
        self.assertIn('codesign --verify --deep --strict "$app"', universal)
        self.assertIn("--kind host --name OpenEmu --arch universal", universal)
        self.assertIn("SOURCE_SHA: ${{ github.sha }}", universal)
        self.assertIn("name: reborn-host-universal", universal)
        self.assertNotIn("-scheme OpenEmu +", universal)
        self.assertNotIn("test-data-folder-app.sh", universal)

    def test_archive_records_exact_digest_and_does_not_claim_archive_signing(self):
        original_output = MODULE.output
        original_run = subprocess.run

        def fake_output(*command):
            return "Xcode fixture" if command[0] == "xcodebuild" else original_output(*command)

        def fixture_tool(command, **_kwargs):
            if command[0] == "git":
                return original_run(command, **_kwargs)
            if command[0] == "ditto":
                with zipfile.ZipFile(command[-1], "w") as archive:
                    for path in self.bundle.rglob("*"):
                        if path.is_file():
                            archive.write(path, path.relative_to(self.bundle.parent))
            elif command[0] != "codesign" and not command[0].endswith("verify-bundle-architectures.sh"):
                self.fail(f"unexpected tool {command}")

        with patch.object(MODULE, "output", side_effect=fake_output), \
             patch.object(MODULE.subprocess, "run", side_effect=fixture_tool), \
             patch.dict(MODULE.os.environ, {"GITHUB_REPOSITORY": "fixture/repo", "GITHUB_RUN_ID": "123"}):
            MODULE.package(self.args)
        metadata = json.loads((self.args.output / "BUILD-INFO.json").read_text())
        archive = self.args.output / metadata["archive"]
        self.assertEqual(metadata["source_sha"], self.revision)
        self.assertEqual(metadata["archive_sha256"], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertEqual(metadata["archive_size"], archive.stat().st_size)
        self.assertEqual(metadata["architecture"], "arm64")
        self.assertFalse(metadata["archive_signed"])
        with zipfile.ZipFile(archive) as zipped:
            self.assertEqual(zipped.read("Nestopia.oecoreplugin/Contents/MacOS/Nestopia"), b"synthetic executable")

        self.make_host_fixture()
        self.args.output = self.root / "host-artifact"
        with patch.object(MODULE, "output", side_effect=fake_output), \
             patch.object(MODULE.subprocess, "run", side_effect=fixture_tool):
            MODULE.package(self.args)
        metadata = json.loads((self.args.output / "BUILD-INFO.json").read_text())
        self.assertEqual(metadata["kind"], "host")
        self.assertEqual(metadata["archive"], "OpenEmu-arm64.app.zip")
        self.assertEqual(metadata["source_sha"], self.revision)


if __name__ == "__main__":
    unittest.main()
