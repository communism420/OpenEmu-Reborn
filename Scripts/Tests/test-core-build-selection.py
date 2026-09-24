#!/usr/bin/env python3
"""Offline core-selection fixtures: no build, network, signing or Git writes."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "select-core-builds.py"
SPEC = importlib.util.spec_from_file_location("select_core_builds", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CoreSelectionTests(unittest.TestCase):
    def selection(self, *paths):
        return MODULE.select("pull_request", list(paths))

    def assert_full(self, result):
        self.assertEqual(result["cores"], list(MODULE.CORES))
        self.assertIs(result["mame"], True)

    def assert_host_only(self, *paths):
        result = self.selection(*paths)
        self.assertEqual(result["cores"], [])
        self.assertIs(result["mame"], False)

    def test_non_pr_events_always_build_every_core(self):
        for event in ("push", "workflow_dispatch", "merge_group", "unknown"):
            with self.subTest(event=event):
                self.assert_full(MODULE.select(event, ["README.md"]))

    def test_exact_native_core_matrix_is_preserved(self):
        self.assertEqual(len(MODULE.CORES), 27)
        self.assertEqual(len(set(MODULE.CORES)), 27)
        self.assertNotIn("MAME", MODULE.CORES)

    def test_every_core_directory_selects_its_own_core(self):
        for core in MODULE.CORES:
            directory = MODULE.CORE_DIRS.get(core, core)
            for filename in ("GameCore.m", "Core.xcodeproj/project.pbxproj",
                             "Core.xcodeproj/xcshareddata/xcschemes/Core.xcscheme"):
                with self.subTest(core=core, filename=filename):
                    result = self.selection(f"{directory}/{filename}")
                    self.assertEqual(result["cores"], [core])
                    self.assertIs(result["mame"], True)

    def test_multiple_cores_use_stable_order_and_no_duplicates(self):
        result = self.selection("SNES9x/source.cpp", "Nestopia/core.mm", "SNES9x/Info.plist")
        self.assertEqual(result["cores"], ["Nestopia", "SNES9x"])

    def test_host_ui_and_translations_skip_cores_including_mame(self):
        self.assert_host_only("OpenEmu/OEDataFolderSetup.swift", "OpenEmu/OEFolderBackupManager.swift",
                              "OpenEmu/OEInterfaceLanguage.swift", "OpenEmu/OpenEmuLaunch.swift",
                              "OpenEmu/ar.lproj/Localizable.strings", "docs/data-folder.md")

    def test_host_source_registration_keeps_previous_core_scope(self):
        self.assert_host_only("OpenEmu/OpenEmu.xcodeproj/project.pbxproj",
                              "OpenEmu/OpenEmu.xcodeproj/xcshareddata/xcschemes/OpenEmu.xcscheme",
                              "OpenEmu/Config.xcconfig", "OpenEmu/CodeSignDefault.xcconfig")

    def test_only_exact_reviewed_host_fixtures_skip_cores(self):
        for path in MODULE.HOST_CHECKS:
            with self.subTest(path=path):
                self.assert_host_only(path)
                self.assert_full(self.selection(path + ".unreviewed"))

    def test_no_blanket_tests_or_script_exemption(self):
        for path in ("Scripts/Tests/new-test.py", "Scripts/Tests/test-core-build-selection.py",
                     "Scripts/select-core-builds.py", "Scripts/new-tool.py",
                     "Scripts/check-core-artifact-reuse.py", "Scripts/prepare-core-ci-scheme.py",
                     "Scripts/package-ci-artifact.py", "Scripts/install-core.sh",
                     "Scripts/verify-bundle-architectures.sh", "Scripts/build-mame-core.sh",
                     "Scripts/prepare-mame-core.sh", "Scripts/package-mame-source.py"):
            with self.subTest(path=path):
                self.assert_full(self.selection(path))

    def test_shared_dependencies_and_workflows_build_every_core(self):
        for path in ("OpenEmu-SDK/OpenEmuBase/OEGameCore.m", "OpenEmu-SDK/Config.xcconfig",
                     "OpenEmuKit/Source/OERingBuffer.m", "OpenEmuKit/Config.xcconfig",
                     "OpenEmu-metal.xcworkspace/contents.xcworkspacedata",
                     "OpenEmu-metal.xcworkspace/xcshareddata/xcschemes/OpenEmu + Nestopia.xcscheme",
                     "OpenEmu/SystemPlugins/Arcade/OEArcadeSystemResponderClient.h",
                     "OpenEmu/SystemPlugins/NES/OENESSystemResponderClient.h",
                     ".github/workflows/build-check.yml", ".github/workflows/intel-test-build.yml"):
            with self.subTest(path=path):
                self.assert_full(self.selection(path))

    def test_host_fixture_does_not_hide_a_shared_change(self):
        self.assert_full(self.selection(*MODULE.HOST_CHECKS, "OpenEmu-SDK/changed.m"))

    def test_mame_inputs_keep_dedicated_job(self):
        for path in ("MAME/deps-mame-revision.txt", "MAME/patches/fix.patch",
                     "MAME/MAME.xcodeproj/project.pbxproj"):
            result = self.selection(path)
            self.assertEqual(result["cores"], [])
            self.assertIs(result["mame"], True)

    def test_rcheevos_selects_all_eleven_direct_consumers(self):
        result = self.selection("Vendor/rcheevos/rcheevos_build.c")
        self.assertEqual(set(result["cores"]), MODULE.RCHEEVOS_CORES)
        self.assertEqual(len(result["cores"]), 11)
        self.assertIn("DeSmuME", result["cores"])
        self.assertIn("Stella", result["cores"])
        self.assertIs(result["mame"], True)

    @unittest.skipUnless(sys.platform == "darwin", "Xcode projects are parsed by macOS plutil")
    def test_rcheevos_policy_matches_real_core_source_build_phases(self):
        # Parse the actual plist object graph, not comments or unused file refs.
        # Only the native plugin target's Sources phases count as consumers.
        root = SCRIPT.parent.parent
        consumers = set()
        for core in MODULE.CORES:
            directory = root / MODULE.CORE_DIRS.get(core, core)
            for project in directory.rglob("project.pbxproj"):
                objects = json.loads(subprocess.check_output([
                    "/usr/bin/plutil", "-convert", "json", "-o", "-", str(project),
                ]))["objects"]
                for target in objects.values():
                    if target.get("isa") != "PBXNativeTarget":
                        continue
                    product = objects.get(target.get("productReference"), {})
                    if product.get("path") != core + ".oecoreplugin":
                        continue
                    for phase_id in target.get("buildPhases", []):
                        phase = objects[phase_id]
                        if phase.get("isa") != "PBXSourcesBuildPhase":
                            continue
                        for build_id in phase.get("files", []):
                            source = objects.get(objects[build_id].get("fileRef"), {})
                            if Path(source.get("path", "")).name == "rcheevos_build.c":
                                consumers.add(core)
        self.assertEqual(consumers, MODULE.RCHEEVOS_CORES)

    def test_unknown_dependency_keeps_existing_mame_check(self):
        for path in ("Vendor/unknown/header.h", "OpenEmu-Shaders/Config.xcconfig",
                     ".github/core-artifact-reuse.json", "NewDependency/source.c"):
            with self.subTest(path=path):
                self.assertIs(self.selection(path)["mame"], True)

    def test_both_sides_of_rename_are_considered(self):
        self.assert_full(self.selection("OpenEmu-SDK/old.m", "docs/new.md"))
        self.assert_full(self.selection("docs/old.md", "OpenEmu-SDK/new.m"))
        self.assertEqual(self.selection("Nestopia/old.m", "docs/new.md")["cores"], ["Nestopia"])

    def test_directory_prefixes_require_separator(self):
        self.assertEqual(self.selection("Nestopia-not-a-core/file")["cores"], [])
        self.assertIs(self.selection("OpenEmu-not-host/file")["mame"], True)

    def test_invalid_changed_paths_fail_closed(self):
        for path in ("", "/OpenEmu/file", "../OpenEmu/file", "OpenEmu/../Scripts/build.sh",
                     "OpenEmu//file", "./OpenEmu/file", "OpenEmu/file\x00", None, 42):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.selection(path)

    def test_empty_pr_diff_selects_no_jobs(self):
        self.assert_host_only()

    def test_cli_nul_list_preserves_spaces_and_newlines(self):
        with tempfile.TemporaryDirectory(prefix="openemu-core-selection-") as directory:
            path = Path(directory) / "changed-paths"
            path.write_bytes(b"OpenEmu/ja.lproj/Localizable.strings\x00docs/a name\nwith newline.md\x00")
            result = subprocess.run([sys.executable, str(SCRIPT), "--event", "pull_request",
                                     "--changed-paths-null", str(path)], capture_output=True, check=True)
            self.assertEqual(json.loads(result.stdout)["cores"], [])
            self.assertFalse(json.loads(result.stdout)["mame"])

    def test_cli_rejects_missing_or_truncated_diff(self):
        with tempfile.TemporaryDirectory(prefix="openemu-core-selection-") as directory:
            path = Path(directory) / "changed-paths"
            path.write_bytes(b"OpenEmu/OnlyHost.swift")
            for args in ([], ["--changed-paths-null", str(path)]):
                result = subprocess.run([sys.executable, str(SCRIPT), "--event", "pull_request", *args],
                                        capture_output=True, check=False)
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
