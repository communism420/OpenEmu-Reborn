#!/usr/bin/env python3
"""Exercise core installs only in private fixtures, with no real app or defaults."""

import os
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import uuid


SCRIPTS = Path(__file__).resolve().parents[1]


class CoreDataFolderTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix="openemu-core-folder-tests-", dir="/private/tmp")
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.scripts = self.root / "Scripts"
        self.scripts.mkdir()
        for name in ("install-core.sh", "verify-core-installed.sh", "core-data-folder.sh"):
            shutil.copy2(SCRIPTS / name, self.scripts / name)
        self.core = "StorageFixture" + uuid.uuid4().hex
        self.folder = self.root / "Chosen data folder"
        self.folder.mkdir()
        self.identifier = str(uuid.uuid4()).upper()
        self.marker = self.folder / ".openemu-data-folder.plist"
        self.write_marker()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.environment = os.environ.copy()
        self.environment["PATH"] = str(self.bin) + os.pathsep + self.environment["PATH"]
        self.environment["OE_TEST_DEFAULTS_LOG"] = str(self.root / "defaults-calls")
        self.environment["OE_TEST_PGREP_LOG"] = str(self.root / "pgrep-calls")
        self.environment["OE_TEST_OSASCRIPT_LOG"] = str(self.root / "osascript-calls")
        self.shim("defaults", '''#!/bin/bash
printf '%s\\n' "$*" >> "$OE_TEST_DEFAULTS_LOG"
[ "$1" = read ] && [ "$2" = org.openemu.OpenEmu ] || exit 99
case "$3" in
  OEDataFolderPath) [ -n "${OE_TEST_SAVED_PATH+x}" ] || exit 1; printf '%s\\n' "$OE_TEST_SAVED_PATH" ;;
  OEDataFolderIdentifier) [ -n "${OE_TEST_SAVED_ID+x}" ] || exit 1; printf '%s\\n' "$OE_TEST_SAVED_ID" ;;
  OEDataFolderBookmark) [ -n "${OE_TEST_SAVED_BOOKMARK+x}" ] || exit 1; printf '%s\\n' "$OE_TEST_SAVED_BOOKMARK" ;;
  *) exit 99 ;;
esac
''')
        self.shim("pgrep", '#!/bin/bash\nprintf "fixture only\\n" >> "$OE_TEST_PGREP_LOG"\nexit 1\n')
        self.shim("osascript", '#!/bin/bash\nprintf "must never run\\n" >> "$OE_TEST_OSASCRIPT_LOG"\nexit 99\n')
        for configuration in ("Debug", "Release"):
            bundle = self.root / self.core / "build/XcodeDerived/Build/Products" / configuration / (self.core + ".oecoreplugin")
            (bundle / "Contents/MacOS").mkdir(parents=True)
            (bundle / "Contents/MacOS" / self.core).write_bytes(("fixture " + configuration).encode())
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": self.core}))

    def tearDown(self):
        self.assertFalse((self.root / "osascript-calls").exists(), "test attempted to quit an application")

    def shim(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def write_marker(self, version=1, identifier=None):
        self.marker.write_bytes(plistlib.dumps({"version": version, "identifier": identifier or self.identifier}))

    def run_script(self, name, *arguments):
        return subprocess.run(["/bin/bash", str(self.scripts / name), *arguments], env=self.environment,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def remember_folder(self):
        self.environment["OE_TEST_SAVED_PATH"] = str(self.folder)
        self.environment["OE_TEST_SAVED_ID"] = self.identifier
        self.environment["OE_TEST_SAVED_BOOKMARK"] = "fixture-bookmark"

    def assert_invalid_folder(self, *arguments):
        for name in ("install-core.sh", "verify-core-installed.sh"):
            result = self.run_script(name, self.core, *arguments)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse((self.root / "pgrep-calls").exists(), "invalid folder reached app control")

    def test_explicit_folder_install_and_verify_debug_and_release(self):
        for configuration in ("debug", "release"):
            options = (self.core, "--" + configuration, "--data-folder", str(self.folder))
            installed = self.run_script("install-core.sh", *options)
            self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
            verified = self.run_script("verify-core-installed.sh", *options)
            self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)
            self.assertIn("OK", verified.stdout)
        self.assertFalse((self.root / "defaults-calls").exists(), "explicit path consulted user settings")

    def test_remembered_folder_install_and_verify(self):
        self.remember_folder()
        for script in ("install-core.sh", "verify-core-installed.sh"):
            result = self.run_script(script, self.core)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.folder / "Cores" / (self.core + ".oecoreplugin")).is_dir())

    def test_missing_remembered_folder_does_not_fall_back(self):
        self.remember_folder()
        self.environment["OE_TEST_SAVED_PATH"] = str(self.root / "disconnected disk")
        self.assert_invalid_folder()
        self.assertFalse((self.root / "disconnected disk").exists())

    def test_remembered_folder_identity_mismatch_is_rejected(self):
        self.remember_folder()
        self.environment["OE_TEST_SAVED_ID"] = str(uuid.uuid4())
        self.assert_invalid_folder()

    def test_incomplete_bootstrap_does_not_fall_back(self):
        for key in ("OE_TEST_SAVED_PATH", "OE_TEST_SAVED_ID", "OE_TEST_SAVED_BOOKMARK"):
            self.environment[key] = str(self.folder)
            self.assert_invalid_folder()
            del self.environment[key]

    def test_invalid_markers_are_rejected(self):
        for version, identifier in ((2, self.identifier), (1, "not-a-uuid")):
            self.write_marker(version, identifier)
            self.assert_invalid_folder("--data-folder", str(self.folder))
        self.marker.unlink()
        self.assert_invalid_folder("--data-folder", str(self.folder))

    def test_symbolic_links_cannot_redirect_marker_or_cores(self):
        other_marker = self.root / "other-marker.plist"
        self.marker.rename(other_marker)
        self.marker.symlink_to(other_marker)
        self.assert_invalid_folder("--data-folder", str(self.folder))
        self.marker.unlink()
        self.write_marker()
        (self.folder / "Cores").symlink_to(self.root)
        self.assert_invalid_folder("--data-folder", str(self.folder))

    def test_argument_errors(self):
        invalid_options = (("--data-folder",), ("--data-folder", "--release"),
                           ("--data-folder", ""), ("--data-folder", str(self.folder), "--data-folder", str(self.folder)))
        for options in invalid_options:
            self.assert_invalid_folder(*options)
        for script in ("install-core.sh", "verify-core-installed.sh"):
            result = self.run_script(script, "../OtherCore", "--data-folder", str(self.folder))
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_stale_bundle_is_detected_in_explicit_folder(self):
        options = (self.core, "--data-folder", str(self.folder))
        result = self.run_script("install-core.sh", *options)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        (self.folder / "Cores" / (self.core + ".oecoreplugin") / "extra-file").write_text("stale")
        result = self.run_script("verify-core-installed.sh", *options)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("--data-folder", result.stderr)

    def test_explicit_derived_data_never_falls_back_to_another_build(self):
        derived = self.root / "Selected DerivedData"
        derived.mkdir()
        options = (self.core, "--data-folder", str(self.folder), "--derived-data", str(derived))
        self.assertEqual(self.run_script("install-core.sh", *options).returncode, 1)
        self.assertEqual(self.run_script("verify-core-installed.sh", *options).returncode, 4)
        self.assertFalse((self.folder / "Cores").exists())

        source = self.root / self.core / "build/XcodeDerived/Build/Products/Debug" / (self.core + ".oecoreplugin")
        destination = derived / "Build/Products/Debug" / source.name
        shutil.copytree(source, destination)
        (destination / "Contents/MacOS" / self.core).write_bytes(b"explicit build, not the discoverable build")
        for script in ("install-core.sh", "verify-core-installed.sh"):
            result = self.run_script(script, *options)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_invalid_derived_data_arguments(self):
        for script in ("install-core.sh", "verify-core-installed.sh"):
            for options in (("--derived-data",), ("--derived-data", "--release"),
                            ("--derived-data", str(self.root / "missing")),
                            ("--derived-data", str(self.root), "--derived-data", str(self.root))):
                result = self.run_script(script, self.core, "--data-folder", str(self.folder), *options)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def prepare_verify_fixture(self):
        # Contract tests for shell argument routing, not substitutes for an
        # actual build/signature check. Every external build/UI command is fake.
        shutil.copy2(SCRIPTS / "verify.sh", self.scripts / "verify.sh")
        self.environment["OE_TEST_WORKSPACE"] = str(self.root)
        for name in ("xcodebuild", "codesign", "git", "pkill", "sleep", "log", "open", "mktemp", "find", "pgrep"):
            self.shim(name, '''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, tempfile
name = pathlib.Path(sys.argv[0]).name
root = pathlib.Path(os.environ["OE_TEST_WORKSPACE"])
with (root / "tool-calls").open("a") as stream:
    stream.write(json.dumps([name, *sys.argv[1:]]) + "\\n")
if name == "git":
    sys.exit(1)
if name == "codesign":
    sys.exit(int(os.environ.get("OE_TEST_CODESIGN_FAILURE", "0")))
if name == "mktemp":
    handle, path = tempfile.mkstemp(dir=root)
    os.close(handle)
    print(path)
elif name == "open":
    (root / "launched-fixture").touch()
elif name == "pgrep":
    sys.exit(0 if (root / "launched-fixture").exists() else 1)
elif name == "find":
    if "Library/Developer/Xcode/DerivedData" in sys.argv[1]:
        print("Unexpected global DerivedData access", file=sys.stderr)
        sys.exit(99)
    if "DiagnosticReports" not in sys.argv[1]:
        sys.exit(subprocess.call(["/usr/bin/find", *sys.argv[1:]]))
elif name == "xcodebuild" and "test" in sys.argv:
    print("fixture test passed")
''')
        for name in ("check-core-feed-urls.sh", "verify-bundle-architectures.sh"):
            fixture = self.scripts / name
            fixture.write_text('#!/bin/bash\nexit 0\n')
            fixture.chmod(0o755)
        self.derived = self.root / "Selected DerivedData"
        self.derived.mkdir()

    def verify_calls(self, command):
        return [row for row in map(json.loads, (self.root / "tool-calls").read_text().splitlines()) if row[0] == command]

    def test_verify_forwards_derived_data_signing_tests_and_launch(self):
        self.prepare_verify_fixture()
        artifact = self.derived / "Build/Products/Release/OpenEmu.app"
        artifact.mkdir(parents=True)
        result = self.run_script("verify.sh", "--derived-data", str(self.derived), "--data-folder", str(self.folder),
                                 "--ad-hoc-sign", "--release", "--test", "--launch", "--arch", "x86_64")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.verify_calls("xcodebuild")
        self.assertEqual([row[-1] for row in calls], ["build", "analyze", "test"])
        for row in calls:
            self.assertEqual(row[row.index("-derivedDataPath") + 1], str(self.derived))
            self.assertEqual(row[row.index("-configuration") + 1], "Release")
            for flag in ("CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES",
                         "CODE_SIGNING_REQUIRED=NO", "DEVELOPMENT_TEAM=", "ARCHS=x86_64", "ONLY_ACTIVE_ARCH=YES"):
                self.assertIn(flag, row)
        self.assertEqual(self.verify_calls("open"), [["open", str(artifact), "--args", "--data-folder", str(self.folder)]])
        self.assertTrue(self.verify_calls("codesign"), "ad-hoc mode skipped signature verification")
        self.assertFalse(any("Library/Developer/Xcode/DerivedData" in str(row) for row in self.verify_calls("find")))

    def test_verify_core_installs_exact_explicit_build(self):
        self.prepare_verify_fixture()
        source = self.root / self.core / "build/XcodeDerived/Build/Products/Debug" / (self.core + ".oecoreplugin")
        artifact = self.derived / "Build/Products/Debug" / source.name
        shutil.copytree(source, artifact)
        (artifact / "Contents/MacOS" / self.core).write_bytes(b"explicit verify build")
        result = self.run_script("verify.sh", "--derived-data", str(self.derived), "--data-folder", str(self.folder),
                                 "--ad-hoc-sign", "--core", self.core)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        installed = self.folder / "Cores" / source.name / "Contents/MacOS" / self.core
        self.assertEqual(installed.read_bytes(), b"explicit verify build")
        self.assertFalse((self.root / "defaults-calls").exists())

    def test_verify_ad_hoc_signing_does_not_skip_signature_failure(self):
        self.prepare_verify_fixture()
        (self.derived / "Build/Products/Debug/OpenEmu.app").mkdir(parents=True)
        self.environment["OE_TEST_CODESIGN_FAILURE"] = "1"
        result = self.run_script("verify.sh", "--derived-data", str(self.derived), "--ad-hoc-sign")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FAIL  codesign", result.stdout)

    def test_verify_argument_errors_do_not_start_a_build(self):
        self.prepare_verify_fixture()
        for options in (("--derived-data",), ("--data-folder",), ("--data-folder", str(self.root / "missing")),
                        ("--derived-data", str(self.root / "missing")),
                        ("--derived-data", str(self.derived), "--worktree")):
            result = self.run_script("verify.sh", *options)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse(self.verify_calls("xcodebuild"))

    def test_absent_bootstrap_retains_legacy_read_only_resolution(self):
        result = subprocess.run(["/bin/bash", "-c", 'source "$1"; oe_core_data_folder', "fixture",
                                 str(self.scripts / "core-data-folder.sh")], env=self.environment,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(Path.home() / "Library/Application Support/OpenEmu"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
