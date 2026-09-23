#!/usr/bin/env python3
# Copyright (c) 2026, OpenEmu Team
# SPDX-License-Identifier: BSD-2-Clause

"""Exercise the real panel watchdog without launching AppKit or waiting."""

import contextlib
import io
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock, call, patch


def watchdog_code():
    script = Path(__file__).with_name("test-data-folder-panel.sh")
    source = script.read_text(encoding="utf-8")
    marker = "<<'PY' || panel_failed=1\n"
    if source.count(marker) != 1:
        raise AssertionError("Expected exactly one panel watchdog Python heredoc")
    body = source.split(marker, 1)[1]
    if "\nPY\n" not in body:
        raise AssertionError("Panel watchdog Python heredoc is not terminated")
    return compile(body.split("\nPY\n", 1)[0], str(script), "exec")


class PanelWatchdogTests(unittest.TestCase):
    def run_watchdog(self, waits, expected_status, *, sampled=False,
                     killed=False, sampling_error=None):
        process = Mock(pid=4321)
        process.wait.side_effect = waits
        output = io.StringIO()
        # The real program sees time advance to 44s after stack collection,
        # leaving one second from its unchanged 45s total allowance.
        with patch("subprocess.Popen", return_value=process) as start, \
                patch("subprocess.run", side_effect=sampling_error) as sample, \
                patch("time.monotonic", side_effect=[0, 44]), \
                patch.object(sys, "argv", ["watchdog", "panel-fixture", "ru"]), \
                contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as stopped:
                exec(watchdog_code(), {"__name__": "__main__"})
        self.assertEqual(stopped.exception.code, expected_status)
        start.assert_called_once_with(["panel-fixture", "-AppleLanguages", "(ru)"])
        expected_waits = [call(timeout=40)]
        if sampled:
            sample.assert_called_once_with(
                ["/usr/bin/sample", "4321", "1", "10"], timeout=4, check=False)
            expected_waits.append(call(timeout=1))
        else:
            sample.assert_not_called()
        if killed:
            process.kill.assert_called_once_with()
            expected_waits.append(call())
            self.assertIn("exceeded its 45-second deadline", output.getvalue())
        else:
            process.kill.assert_not_called()
            self.assertNotIn("FAIL:", output.getvalue())
        self.assertEqual(process.wait.call_args_list, expected_waits)
        return output.getvalue()

    def test_success_does_not_sample_or_kill(self):
        self.run_watchdog([0], 0)

    def test_fixture_failure_is_preserved(self):
        self.run_watchdog([3], 3)

    def test_signal_is_reported_as_failure(self):
        self.run_watchdog([-9], 1)

    def test_completion_during_sampling_still_passes(self):
        self.run_watchdog([subprocess.TimeoutExpired("fixture", 40), 0],
                          0, sampled=True)

    def test_deadline_kills_and_reaps_the_fixture(self):
        self.run_watchdog([subprocess.TimeoutExpired("fixture", 40),
                           subprocess.TimeoutExpired("fixture", 1), 0],
                          1, sampled=True, killed=True)

    def test_sampling_timeout_does_not_bypass_the_deadline(self):
        output = self.run_watchdog(
            [subprocess.TimeoutExpired("fixture", 40),
             subprocess.TimeoutExpired("fixture", 1), 0],
            1, sampled=True, killed=True,
            sampling_error=subprocess.TimeoutExpired("sample", 4))
        self.assertIn("four-second diagnostic limit", output)

    def test_missing_sampler_does_not_bypass_the_deadline(self):
        output = self.run_watchdog(
            [subprocess.TimeoutExpired("fixture", 40),
             subprocess.TimeoutExpired("fixture", 1), 0],
            1, sampled=True, killed=True,
            sampling_error=OSError("sample unavailable"))
        self.assertIn("stack sampling unavailable", output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
