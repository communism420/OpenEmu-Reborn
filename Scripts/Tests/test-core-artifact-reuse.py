#!/usr/bin/env python3
"""Offline policy fixtures; no GitHub, downloads, builds, signing or Git writes."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import MagicMock, patch


SPEC = importlib.util.spec_from_file_location(
    "core_artifact_reuse", Path(__file__).resolve().parents[1] / "check-core-artifact-reuse.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SCHEME = b'''<Scheme version="1.3"><BuildAction buildImplicitDependencies="YES"/>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES">
<Testables><TestableReference skipped="NO"/></Testables></TestAction>
<LaunchAction buildConfiguration="Debug"/></Scheme>'''
ARGS = b'''<CommandLineArguments>
<CommandLineArgument argument="-SUEnableAutomaticChecks NO" isEnabled="YES"/>
<CommandLineArgument argument="-ApplePersistenceIgnoreState YES" isEnabled="YES"/>
</CommandLineArguments>'''
WORKFLOW = b'''name: Fixture
jobs:
  build-cores:
    if: original-selector
    needs: detect-core-changes
    steps:
      - run: xcodebuild ARCHS=matrix.arch
  build-mame:
    if: original-selector
    steps:
      - run: ./Scripts/build-mame-core.sh
  build:
    steps:
      - name: Select Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: '26.5'
      - run: host-tests
'''


def snapshot():
    reference = MODULE.REFERENCE
    info = {"SUPublicEDKey": "public-fixture-only", "OECoreUpdateCatalogs": {
        arch: f"https://example.invalid/{arch}/oecores.xml" for arch in MODULE.ARCHITECTURES}}
    return {"current_source_sha": "b" * 40, "source_sha": reference["source_sha"],
            "source_parents": [reference["base_sha"], reference["head_sha"]],
            "source_tree": reference["source_tree"], "head_tree": reference["source_tree"],
            "changed_files": ["OpenEmu/AppDelegate.swift"],
            "current_modes": {name: "100644" for name in MODULE.ALLOWED_CHANGES},
            "source_info": info, "current_info": copy.deepcopy(info),
            "source_catalog": b"<cores/>", "current_catalog": b"<cores/>",
            "source_scheme": SCHEME, "current_scheme": SCHEME,
            "source_workflow": WORKFLOW, "current_workflow": WORKFLOW}


def remote():
    reference = MODULE.REFERENCE
    run = {"id": reference["run_id"], "status": "completed", "conclusion": "failure", "run_attempt": 2,
           "event": "pull_request", "path": reference["workflow_path"], "head_sha": reference["head_sha"],
           "repository": {"id": reference["repository_id"], "full_name": reference["repository"]},
           "head_repository": {"id": reference["repository_id"], "full_name": reference["repository"]}}
    jobs, artifacts = [], []
    for core in MODULE.CORES:
        for architecture in MODULE.ARCHITECTURES:
            retry = architecture == "x86_64" and core in ("CrabEmu", "Picodrive")
            jobs.append({"name": f"Build core ({core}, {architecture})", "id": len(jobs) + 1,
                         "run_id": reference["run_id"], "run_attempt": 2 if retry else 1,
                         "head_sha": reference["head_sha"], "status": "completed", "conclusion": "success"})
            artifacts.append({"name": f"reborn-core-{core}-{architecture}"})
    artifacts.append({"name": "reborn-mame-source"})
    for index, artifact in enumerate(artifacts):
        artifact.update(id=1000 + index, expired=False, size_in_bytes=123,
                        digest="sha256:" + f"{index:064x}", workflow_run={
                            "id": reference["run_id"], "head_sha": reference["head_sha"],
                            "repository_id": reference["repository_id"],
                            "head_repository_id": reference["repository_id"]})
    jobs.append({"name": "Build (x86_64)", "status": "completed", "conclusion": "failure"})
    artifacts.append({"name": "reborn-host-arm64"})
    return run, jobs, artifacts


class LocalPolicyTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = snapshot()

    def validate(self):
        MODULE.check_local(MODULE.REFERENCE, self.snapshot)

    def test_exact_host_only_paths_allowed(self):
        self.snapshot["changed_files"] = sorted(MODULE.ALLOWED_CHANGES)
        self.validate()

    def test_unchanged_source_allowed(self):
        self.snapshot["changed_files"] = []
        self.validate()

    def test_core_shared_build_and_unknown_paths_require_full_build(self):
        for path in ("CrabEmu/CrabEmuGameCore.m", "MAME/patches/new.patch", "OpenEmu-SDK/foo.m",
                     "OpenEmuKit/foo.swift", "OpenEmu-Shaders/test.metal", "Vendor/rcheevos/rc.c",
                     "OpenEmu/OpenEmu.xcodeproj/project.pbxproj", "Scripts/build-mame-core.sh",
                     "Scripts/Tests/unreviewed-test.py", "OpenEmu/Unreviewed.swift",
                     "Updates/cores/arm64/oecores.xml", "new-file", "tmp/agent/committed-file"):
            with self.subTest(path=path):
                self.snapshot["changed_files"] = [path]
                with self.assertRaisesRegex(ValueError, "unsupported source changes"):
                    self.validate()

    def test_configuration_cannot_expand_allowlist_or_change_run(self):
        for key, value in (("allowed_paths", ["OpenEmu-SDK/foo.m"]), ("run_id", 1),
                           ("source_sha", "f" * 40), ("schema", True)):
            reference = {**MODULE.REFERENCE, key: value}
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "reviewed fixed run/source"):
                MODULE.check_local(reference, self.snapshot)

    def test_wrong_source_parents_or_tree_rejected(self):
        for key, value in (("source_sha", "f" * 40), ("source_parents", []),
                           ("source_tree", "f" * 40), ("head_tree", "f" * 40)):
            with self.subTest(key=key):
                candidate = {**self.snapshot, key: value}
                with self.assertRaises(ValueError):
                    MODULE.check_local(MODULE.REFERENCE, candidate)

    def test_unknown_current_source_rejected(self):
        self.snapshot["current_source_sha"] = "HEAD"
        with self.assertRaisesRegex(ValueError, "must be full"):
            self.validate()

    def test_host_file_deletion_symlink_or_mode_change_rejected(self):
        for mode in ("", "120000", "100755"):
            with self.subTest(mode=mode):
                self.snapshot["current_modes"]["OpenEmu/AppDelegate.swift"] = mode
                with self.assertRaisesRegex(ValueError, "regular source files"):
                    self.validate()

    def test_runtime_key_and_catalog_contract_preserved(self):
        for key in ("SUPublicEDKey", "OECoreUpdateCatalogs"):
            with self.subTest(key=key):
                candidate = copy.deepcopy(self.snapshot)
                candidate["current_info"][key] = "different"
                with self.assertRaisesRegex(ValueError, "trust/catalog contract"):
                    MODULE.check_local(MODULE.REFERENCE, candidate)
        self.snapshot["current_catalog"] = b"changed catalog"
        with self.assertRaisesRegex(ValueError, "native catalog changed"):
            self.validate()

    def test_reviewed_test_arguments_and_xml_whitespace_allowed(self):
        self.snapshot["current_scheme"] = SCHEME.replace(b'shouldUseLaunchSchemeArgsEnv="YES"',
            b'shouldUseLaunchSchemeArgsEnv="NO"').replace(b"<Testables>", ARGS + b"\n  <Testables>")
        self.validate()

    def test_scheme_build_or_launch_changes_rejected(self):
        for before, after in ((b'buildImplicitDependencies="YES"', b'buildImplicitDependencies="NO"'),
                              (b'<LaunchAction buildConfiguration="Debug"', b'<LaunchAction buildConfiguration="Release"')):
            with self.subTest(before=before):
                self.snapshot["current_scheme"] = SCHEME.replace(before, after)
                with self.assertRaisesRegex(ValueError, "outside TestAction"):
                    self.validate()

    def test_scheme_cannot_skip_test_coverage_or_add_arbitrary_flags(self):
        for scheme in (SCHEME.replace(b'skipped="NO"', b'skipped="YES"'),
                       SCHEME.replace(b"<Testables>", ARGS.replace(b"ApplePersistenceIgnoreState", b"DisableAllTests") + b"<Testables>")):
            self.snapshot["current_scheme"] = scheme
            with self.assertRaises(ValueError):
                self.validate()

    def test_workflow_selection_and_host_diagnostics_allowed(self):
        self.snapshot["current_workflow"] = WORKFLOW.replace(b"original-selector", b"checked-reuse-selector").replace(
            b"  build-mame:\n", b"  build-mame:\n    needs: detect-core-changes\n").replace(
            b"      - run: host-tests", b"      - run: host-tests --resultBundlePath fixture")
        self.validate()

    def test_workflow_cannot_change_core_build_settings_or_steps(self):
        for old, new in ((b"ARCHS=matrix.arch", b"ARCHS=arm64"),
                         (b"./Scripts/build-mame-core.sh", b"echo skipped"),
                         (b"build-cores:", b"removed-cores:")):
            self.snapshot["current_workflow"] = WORKFLOW.replace(old, new)
            with self.subTest(old=old), self.assertRaises(ValueError):
                self.validate()

    def test_workflow_global_environment_cannot_change_builds(self):
        self.snapshot["current_workflow"] = WORKFLOW.replace(b"jobs:\n", b"env:\n  ARCHS: arm64\njobs:\n")
        with self.assertRaisesRegex(ValueError, "prefix/global build environment"):
            self.validate()

    def test_workflow_host_xcode_selection_cannot_drift(self):
        self.snapshot["current_workflow"] = WORKFLOW.replace(b"xcode-version: '26.5'", b"xcode-version: 'latest'")
        with self.assertRaisesRegex(ValueError, "host Select Xcode toolchain changed"):
            self.validate()


class RemotePolicyTests(unittest.TestCase):
    def setUp(self):
        self.run, self.jobs, self.artifacts = remote()

    def validate(self):
        return MODULE.check_remote(MODULE.REFERENCE, self.run, self.jobs, self.artifacts)

    def test_host_failure_does_not_discard_complete_core_successes(self):
        result = self.validate()
        self.assertEqual(result["source_run_conclusion"], "failure")
        self.assertEqual(len(result["core_jobs"]), 56)
        self.assertEqual(len(result["artifacts"]), 57)
        self.assertEqual(result["artifacts"][0]["github_artifact_digest"], self.artifacts[0]["digest"])

    def test_mixed_or_carried_forward_attempts_accepted(self):
        self.validate()
        for job in self.jobs[:-1]:
            job["run_attempt"] = 2
        self.validate()

    def test_missing_mame_job_rejected(self):
        self.jobs = [job for job in self.jobs if job["name"] != "Build core (MAME, x86_64)"]
        with self.assertRaisesRegex(ValueError, "all 56 expected core jobs"):
            self.validate()

    def test_failed_skipped_or_incomplete_core_rejected(self):
        for conclusion in ("failure", "skipped", None):
            with self.subTest(conclusion=conclusion):
                self.jobs[0]["conclusion"] = conclusion
                with self.assertRaisesRegex(ValueError, "did not succeed"):
                    self.validate()

    def test_duplicate_core_job_cannot_replace_missing_core(self):
        self.jobs[1] = copy.deepcopy(self.jobs[0])
        with self.assertRaisesRegex(ValueError, "all 56 expected core jobs"):
            self.validate()

    def test_wrong_run_sha_repository_or_incomplete_run_rejected(self):
        for key, value in (("id", 1), ("head_sha", "f" * 40), ("status", "in_progress"),
                           ("path", "other.yml"), ("event", "workflow_dispatch"),
                           ("head_repository", {"id": 1, "full_name": MODULE.REFERENCE["repository"]})):
            with self.subTest(key=key):
                candidate = {**self.run, key: value}
                with self.assertRaises(ValueError):
                    MODULE.check_remote(MODULE.REFERENCE, candidate, self.jobs, self.artifacts)

    def test_wrong_job_source_or_attempt_rejected(self):
        for key, value in (("head_sha", "f" * 40), ("run_id", 1), ("run_attempt", 3), ("run_attempt", 0)):
            with self.subTest(key=key):
                candidate = copy.deepcopy(self.jobs)
                candidate[0][key] = value
                with self.assertRaisesRegex(ValueError, "source/run/attempt"):
                    MODULE.check_remote(MODULE.REFERENCE, self.run, candidate, self.artifacts)

    def test_expired_or_empty_core_and_mame_source_rejected(self):
        for name in ("reborn-core-4DO-arm64", "reborn-mame-source"):
            for key, value in (("expired", True), ("expired", None), ("size_in_bytes", 0)):
                with self.subTest(name=name, key=key):
                    candidate = copy.deepcopy(self.artifacts)
                    next(item for item in candidate if item["name"] == name)[key] = value
                    with self.assertRaisesRegex(ValueError, "expired or empty"):
                        MODULE.check_remote(MODULE.REFERENCE, self.run, self.jobs, candidate)

    def test_missing_or_duplicate_artifact_rejected(self):
        for items in (self.artifacts[1:], self.artifacts[:-2] + [self.artifacts[-1]],
                      self.artifacts + [self.artifacts[0]],
                      self.artifacts + [{"name": "reborn-core-unreviewed-arm64"}]):
            with self.subTest(count=len(items)), self.assertRaisesRegex(ValueError, "exactly 56 core artifacts"):
                MODULE.check_remote(MODULE.REFERENCE, self.run, self.jobs, items)

    def test_artifact_digest_and_source_attribution_required(self):
        for key, value in (("digest", None), ("digest", "sha256:bad"), ("workflow_run", {})):
            candidate = copy.deepcopy(self.artifacts)
            candidate[0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                MODULE.check_remote(MODULE.REFERENCE, self.run, self.jobs, candidate)

    def test_malformed_nested_api_metadata_rejected(self):
        for run, jobs, artifacts in (
                ([], self.jobs, self.artifacts),
                ({**self.run, "repository": None}, self.jobs, self.artifacts),
                (self.run, [{"name": None}] + self.jobs, self.artifacts),
                (self.run, self.jobs, [{**self.artifacts[0], "workflow_run": None}] + self.artifacts[1:]),
                (self.run, self.jobs, [None])):
            with self.subTest(run=type(run).__name__), self.assertRaises(ValueError):
                MODULE.check_remote(MODULE.REFERENCE, run, jobs, artifacts)


class WrapperTests(unittest.TestCase):
    def config(self):
        value = MagicMock()
        value.read_text.return_value = json.dumps(MODULE.REFERENCE)
        return value

    def test_machine_output_contains_honest_source_and_still_requires_archive_validation(self):
        run, jobs, artifacts = remote()
        with patch.object(MODULE, "local_snapshot", return_value=snapshot()), \
             patch.object(MODULE, "github_json", return_value=run), \
             patch.object(MODULE, "github_items", side_effect=[jobs, artifacts]):
            result = MODULE.inspect("b" * 40, self.config())
        self.assertTrue(result["reuse"])
        self.assertTrue(result["archive_validation_required"])
        self.assertTrue(result["source_tree_match"])
        self.assertEqual(result["source_sha"], MODULE.REFERENCE["source_sha"])
        self.assertEqual(len(result["artifacts"]), 57)

    def test_unknown_source_change_falls_back_without_any_api_request(self):
        value = snapshot()
        value["changed_files"] = ["OpenEmu-SDK/new.m"]
        with patch.object(MODULE, "local_snapshot", return_value=value), patch.object(MODULE, "github_json") as api:
            result = MODULE.inspect("b" * 40, self.config())
        self.assertFalse(result["reuse"])
        self.assertIn("unsupported source changes", result["reason"])
        api.assert_not_called()

    def test_api_failure_and_missing_git_object_fall_back_not_reuse(self):
        with patch.object(MODULE, "local_snapshot", return_value=snapshot()), \
             patch.object(MODULE, "github_json", side_effect=ValueError("API unavailable")):
            result = MODULE.inspect("b" * 40, self.config())
        self.assertFalse(result["reuse"])
        self.assertIn("API unavailable", result["reason"])
        with patch.object(MODULE, "local_snapshot", side_effect=subprocess.CalledProcessError(128, ["git", "show"])):
            self.assertFalse(MODULE.inspect("b" * 40, self.config())["reuse"])

    def test_malformed_api_response_returns_machine_readable_no_reuse(self):
        with patch.object(MODULE, "local_snapshot", return_value=snapshot()), \
             patch.object(MODULE, "github_json", return_value=None):
            result = MODULE.inspect("b" * 40, self.config())
        self.assertFalse(result["reuse"])
        self.assertIn("invalid GitHub", result["reason"])

    def test_bounded_pagination_preserves_inventory(self):
        pages = [{"total_count": 101, "jobs": list(range(100))}, {"total_count": 101, "jobs": [100]}]
        with patch.object(MODULE, "github_json", side_effect=pages) as api:
            self.assertEqual(MODULE.github_items("fixture?filter=latest", "jobs"), list(range(101)))
            self.assertTrue(api.call_args_list[1].args[0].endswith("&per_page=100&page=2"))

    def test_changed_or_truncated_api_inventory_rejected(self):
        for last in ({"total_count": 2, "jobs": [1]}, {"total_count": 101, "jobs": []}):
            with self.subTest(last=last), patch.object(MODULE, "github_json", side_effect=[
                    {"total_count": 101, "jobs": list(range(100))}, last]):
                with self.assertRaises(ValueError):
                    MODULE.github_items("fixture", "jobs")

    def test_thin_gh_wrapper_only_reads_json_and_handles_network_failure(self):
        with patch.object(MODULE.subprocess, "check_output", return_value=b'{"id":1}') as call:
            self.assertEqual(MODULE.github_json("repos/fixture"), {"id": 1})
            self.assertEqual(call.call_args.args[0], ["gh", "api", "--hostname", "github.com", "repos/fixture"])
        with patch.object(MODULE.subprocess, "check_output", side_effect=subprocess.TimeoutExpired("gh", 60)):
            with self.assertRaisesRegex(ValueError, "permissions and API connectivity"):
                MODULE.github_json("repos/fixture")


if __name__ == "__main__":
    unittest.main()
