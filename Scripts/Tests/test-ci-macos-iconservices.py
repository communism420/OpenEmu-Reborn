#!/usr/bin/env python3
"""Offline fixtures only: never call launchctl or modify real runner services."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "ci_iconservices", Path(__file__).resolve().parents[1] / "ci-macos-iconservices.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
UID = os.getuid()
ENVIRONMENT = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
               "RUNNER_OS": "macOS", "ImageVersion": MODULE.IMAGE_VERSION,
               "GITHUB_RUN_ID": "12345", "GITHUB_RUN_ATTEMPT": "2", "GITHUB_JOB": "native-file-panels"}
CONTEXT = {"schema": 1, "image": MODULE.IMAGE_VERSION, "os_build": MODULE.OS_BUILD, "uid": UID,
           "service": f"gui/{UID}/{MODULE.SERVICE}", "run_id": "12345", "attempt": "2", "job": "native-file-panels"}


def crash_report():
    return ({"app_name": "iconservicesagent", "os_version": "macOS 26.6.1 (25G76)"}, {
        "procName": "iconservicesagent", "procPath": "/System/Library/CoreServices/iconservicesagent",
        "userID": UID, "cpuType": "X86-64", "osVersion": {"build": "25G76"},
        "exception": {"type": "EXC_CRASH", "signal": "SIGABRT"}, "faultingThread": 0,
        "threads": [{"frames": [{"imageIndex": 0, "symbol": MODULE.METAL_SYMBOL},
                                 {"imageIndex": 1, "symbol": "RB::FunctionLibrary::FunctionLibrary"}]}],
        "usedImages": [{"path": "/System/Library/Frameworks/Metal.framework/Versions/A/Metal"},
                       {"path": "/System/Library/PrivateFrameworks/RenderBox.framework/Versions/A/RenderBox"}]})


def encoded(metadata, report):
    return json.dumps(metadata) + "\n" + json.dumps(report) + "\n"


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, ENVIRONMENT, clear=True).start()
        patch.object(MODULE.platform, "system", return_value="Darwin").start()
        patch.object(MODULE.platform, "machine", return_value="x86_64").start()
        self.run = patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess(
            [], 0, "25G76\n", "")).start()

    def test_exact_hosted_image_allowed(self):
        self.assertEqual(MODULE.guarded_context(), CONTEXT)
        self.run.assert_called_once_with(["/usr/bin/sw_vers", "-buildVersion"],
            capture_output=True, text=True, timeout=5, check=False)

    def test_every_environment_guard_required_before_external_command(self):
        for key in ("GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "RUNNER_OS", "ImageVersion"):
            with self.subTest(key=key), patch.dict(os.environ, {key: "different"}):
                self.assertIsNone(MODULE.guarded_context())
        self.run.assert_not_called()

    def test_actual_arm_linux_and_root_rejected_before_external_command(self):
        for attribute, value in (("machine", "arm64"), ("system", "Linux")):
            with self.subTest(attribute=attribute), patch.object(MODULE.platform, attribute, return_value=value):
                self.assertIsNone(MODULE.guarded_context())
        with patch.object(MODULE.os, "getuid", return_value=0):
            self.assertIsNone(MODULE.guarded_context())
        self.run.assert_not_called()

    def test_other_actual_os_build_rejected(self):
        self.run.return_value.stdout = "25G99\n"
        self.assertIsNone(MODULE.guarded_context())

    def test_exact_run_identity_required(self):
        for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB"):
            with self.subTest(key=key), patch.dict(os.environ, {key: "../../bad"}):
                with self.assertRaisesRegex(RuntimeError, "identity"):
                    MODULE.guarded_context()

    def test_guard_command_timeout_is_failure_not_silent_skip(self):
        self.run.side_effect = subprocess.TimeoutExpired("sw_vers", 5)
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            MODULE.guarded_context()

    def test_guard_nonzero_command_is_failure(self):
        self.run.return_value.returncode = 1
        with self.assertRaisesRegex(RuntimeError, "exited 1"):
            MODULE.guarded_context()

    def test_cli_no_action_on_nonmatching_host(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}), patch.object(MODULE, "apply") as apply:
            self.assertEqual(MODULE.main(["apply"]), 0)
            apply.assert_not_called()
            self.run.assert_not_called()


class EvidenceTests(unittest.TestCase):
    def test_full_structured_crash_matches(self):
        self.assertTrue(MODULE.matching_report(encoded(*crash_report()), UID))

    def test_each_identity_exception_or_os_mismatch_rejected(self):
        for key, value in (("procName", "OpenEmu"), ("procPath", "/tmp/iconservicesagent"),
                           ("userID", UID + 1), ("cpuType", "ARM-64"),
                           ("osVersion", {"build": "25G99"}), ("exception", {"signal": "SIGSEGV"}),
                           ("faultingThread", -1), ("faultingThread", True), ("faultingThread", 99)):
            metadata, report = crash_report()
            report[key] = value
            with self.subTest(key=key, value=value):
                self.assertFalse(MODULE.matching_report(encoded(metadata, report), UID))

    def test_metadata_must_match_process_and_os(self):
        for key in ("app_name", "os_version"):
            metadata, report = crash_report()
            metadata[key] = "different"
            self.assertFalse(MODULE.matching_report(encoded(metadata, report), UID))

    def test_symbol_in_free_text_or_nonfaulting_thread_does_not_match(self):
        metadata, report = crash_report()
        report["threads"].append({"frames": []})
        report["faultingThread"] = 1
        report["note"] = MODULE.METAL_SYMBOL + " RenderBox RB::FunctionLibrary"
        self.assertFalse(MODULE.matching_report(encoded(metadata, report), UID))

    def test_both_frame_symbols_and_exact_system_images_required(self):
        for index in (0, 1):
            metadata, report = crash_report()
            report["usedImages"][index]["path"] = "/tmp/Metal"
            self.assertFalse(MODULE.matching_report(encoded(metadata, report), UID))
            metadata, report = crash_report()
            report["threads"][0]["frames"][index]["symbol"] = "unrelated"
            self.assertFalse(MODULE.matching_report(encoded(metadata, report), UID))

    def test_malformed_documents_rejected(self):
        for content in ("", "SIGABRT Metal RenderBox", "{}", "[]\n{}", "{}\nnull",
                        encoded(*crash_report()) + "{}"):
            with self.subTest(content=content[:30]):
                self.assertFalse(MODULE.matching_report(content, UID))

    def test_named_reports_only_and_ignore_symlinks_and_large_files(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder).resolve()
            directory = home / "Library/Logs/DiagnosticReports"
            directory.mkdir(parents=True)
            other = directory / "unrelated.ips"
            other.write_text(encoded(*crash_report()))
            (directory / "iconservicesagent-2026-09-23-123456.ips").symlink_to(other)
            large = directory / "iconservicesagent-2026-09-23-123457.ips"
            large.write_bytes(b"x" * (MODULE.MAX_REPORT_BYTES + 1))
            with patch.object(MODULE.pwd, "getpwuid") as user:
                user.return_value.pw_dir = str(home)
                self.assertIsNone(MODULE.find_evidence(UID))
                matching = directory / "iconservicesagent-2026-09-23-123458.ips"
                matching.write_text(encoded(*crash_report()))
                self.assertEqual(MODULE.find_evidence(UID), matching.name)


class MutationTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(patch.stopall)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.path = self.directory / MODULE.STATE_NAME
        patch.dict(os.environ, {**ENVIRONMENT, "RUNNER_TEMP": str(self.directory)}, clear=True).start()
        self.evidence = patch.object(MODULE, "find_evidence", return_value="iconservicesagent-2026-09-23-123456.ips").start()
        self.run = patch.object(MODULE.subprocess, "run", side_effect=self.success).start()

    @staticmethod
    def success(arguments, **kwargs):
        output = "disabled services = {\n}\n" if arguments[1] == "print-disabled" else ""
        return subprocess.CompletedProcess(arguments, 0, output, "")

    def verbs(self):
        return [call.args[0][1] for call in self.run.call_args_list]

    def test_apply_and_cleanup_restore_only_our_exact_service(self):
        MODULE.apply(CONTEXT)
        self.assertEqual(self.verbs(), ["print-disabled", "disable", "bootout"])
        self.assertTrue(MODULE.load_state(self.path, CONTEXT)["bootout_attempted"])
        MODULE.cleanup(CONTEXT)
        self.assertEqual(self.verbs(), ["print-disabled", "disable", "bootout", "enable", "bootstrap"])
        self.assertFalse(self.path.exists())
        for call in self.run.call_args_list:
            self.assertEqual(call.args[0][0], "/bin/launchctl")
            self.assertEqual(call.kwargs["timeout"], 5)
            self.assertIn(call.args[0][2], (CONTEXT["service"], f"gui/{UID}"))

    def test_no_evidence_or_no_marker_never_calls_launchctl(self):
        self.evidence.return_value = None
        MODULE.apply(CONTEXT)
        MODULE.cleanup(CONTEXT)
        self.run.assert_not_called()
        self.assertFalse(self.path.exists())

    def test_already_disabled_is_not_changed_or_marked_for_cleanup(self):
        self.run.side_effect = lambda arguments, **kwargs: subprocess.CompletedProcess(
            arguments, 0, f'disabled services = {{\n "{MODULE.SERVICE}" => true\n}}\n', "")
        MODULE.apply(CONTEXT)
        MODULE.cleanup(CONTEXT)
        self.assertEqual(self.verbs(), ["print-disabled"])
        self.assertFalse(self.path.exists())

    def test_explicit_enabled_state_is_allowed(self):
        with patch.object(MODULE, "command", return_value=f'disabled services = {{ "{MODULE.SERVICE}" => false }}'):
            self.assertFalse(MODULE.previously_disabled(CONTEXT))

    def test_unknown_or_duplicate_original_state_rejected_before_mutation(self):
        for output in ("", "not a disabled-service list", f'disabled services = {{ "{MODULE.SERVICE}" => unknown }}',
                       f'disabled services = {{ "{MODULE.SERVICE}" => true "{MODULE.SERVICE}" => false }}'):
            self.run.reset_mock()
            self.run.side_effect = lambda args, **kwargs: subprocess.CompletedProcess(args, 0, output, "")
            with self.subTest(output=output), self.assertRaises(RuntimeError):
                MODULE.apply(CONTEXT)
            self.assertEqual(self.verbs(), ["print-disabled"])
            self.assertFalse(self.path.exists())

    def test_command_failures_and_timeouts_fail_and_restore(self):
        for verb in ("disable", "bootout"):
            for timeout in (False, True):
                self.run.reset_mock()
                def response(arguments, **kwargs):
                    if arguments[1] == verb:
                        if timeout:
                            raise subprocess.TimeoutExpired(arguments, 5)
                        return subprocess.CompletedProcess(arguments, 1, "", "fixture error")
                    return self.success(arguments, **kwargs)
                self.run.side_effect = response
                with self.subTest(verb=verb, timeout=timeout), self.assertRaisesRegex(RuntimeError, "original enabled state restored"):
                    MODULE.apply(CONTEXT)
                self.assertIn("enable", self.verbs())
                self.assertEqual("bootstrap" in self.verbs(), verb == "bootout")
                self.assertFalse(self.path.exists())

    def test_failed_recovery_retains_marker_for_always_cleanup(self):
        def response(arguments, **kwargs):
            if arguments[1] in ("bootout", "enable"):
                raise subprocess.TimeoutExpired(arguments, 5)
            return self.success(arguments, **kwargs)
        self.run.side_effect = response
        with self.assertRaisesRegex(RuntimeError, "restoration also failed"):
            MODULE.apply(CONTEXT)
        self.assertTrue(self.path.exists())
        self.run.side_effect = self.success
        MODULE.cleanup(CONTEXT)
        self.assertFalse(self.path.exists())

    def test_unknown_original_state_timeout_never_disables(self):
        self.run.side_effect = subprocess.TimeoutExpired("launchctl", 5)
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            MODULE.apply(CONTEXT)
        self.assertEqual(self.verbs(), ["print-disabled"])
        self.assertFalse(self.path.exists())

    def test_marker_write_failure_after_disable_restores_enabled_state(self):
        original = MODULE.write_state
        def write(path, state, *, create=False):
            if not create:
                raise OSError("fixture write failure")
            return original(path, state, create=create)
        with patch.object(MODULE, "write_state", side_effect=write), self.assertRaisesRegex(
                RuntimeError, "original enabled state restored"):
            MODULE.apply(CONTEXT)
        self.assertNotIn("bootout", self.verbs())
        self.assertIn("enable", self.verbs())
        self.assertFalse(self.path.exists())

    def test_failed_bootstrap_requires_exact_service_still_loaded(self):
        MODULE.apply(CONTEXT)
        def response(arguments, **kwargs):
            if arguments[1] == "bootstrap":
                return subprocess.CompletedProcess(arguments, 5, "", "already loaded")
            return self.success(arguments, **kwargs)
        self.run.side_effect = response
        MODULE.cleanup(CONTEXT)
        self.assertEqual(self.verbs()[-3:], ["enable", "bootstrap", "print"])
        self.assertFalse(self.path.exists())

    def test_failed_bootstrap_and_verification_are_not_hidden(self):
        MODULE.apply(CONTEXT)
        def response(arguments, **kwargs):
            if arguments[1] in ("bootstrap", "print"):
                return subprocess.CompletedProcess(arguments, 5, "", "failure")
            return self.success(arguments, **kwargs)
        self.run.side_effect = response
        with self.assertRaises(RuntimeError):
            MODULE.cleanup(CONTEXT)
        self.assertTrue(self.path.exists())

    def test_existing_marker_blocks_repeat_application(self):
        MODULE.apply(CONTEXT)
        self.run.reset_mock()
        with self.assertRaisesRegex(RuntimeError, "cleanup first"):
            MODULE.apply(CONTEXT)
        self.run.assert_not_called()

    def test_foreign_job_state_cannot_restore_a_service(self):
        state = {**CONTEXT, "restore_enabled": True, "bootout_attempted": True}
        for key, value in (("run_id", "999"), ("attempt", "3"), ("job", "other-job"),
                           ("uid", UID + 1), ("service", f"gui/{UID}/other.service"),
                           ("image", "other"), ("restore_enabled", False), ("bootout_attempted", 1)):
            altered = {**state, key: value}
            self.path.write_text(json.dumps(altered))
            self.path.chmod(0o600)
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                MODULE.cleanup(CONTEXT)
            self.run.assert_not_called()

    def test_symlink_or_public_state_file_is_never_followed(self):
        other = self.directory / "unrelated"
        other.write_text("untouched")
        self.path.symlink_to(other)
        with self.assertRaises(OSError):
            MODULE.cleanup(CONTEXT)
        self.assertEqual(other.read_text(), "untouched")
        self.path.unlink()
        self.path.write_text("{}")
        self.path.chmod(0o644)
        with self.assertRaises(ValueError):
            MODULE.cleanup(CONTEXT)
        self.run.assert_not_called()

    def test_unsafe_temp_roots_rejected(self):
        symlink = self.directory / "linked"
        symlink.symlink_to(self.directory, target_is_directory=True)
        for location in ("", "/", ".", str(symlink), str(self.directory / "missing")):
            with self.subTest(location=location), patch.dict(os.environ, {"RUNNER_TEMP": location}):
                with self.assertRaises(RuntimeError):
                    MODULE.state_path()
        self.directory.chmod(0o777)
        with self.assertRaises(RuntimeError):
            MODULE.state_path()
        self.run.assert_not_called()

    def test_cli_reports_mutation_failure_as_failure(self):
        with patch.object(MODULE, "guarded_context", return_value=CONTEXT), patch.object(
                MODULE, "apply", side_effect=RuntimeError("fixture failure")):
            self.assertEqual(MODULE.main(["apply"]), 1)
        self.run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
