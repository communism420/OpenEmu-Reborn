#!/usr/bin/env python3
"""Offline guards only. No downloads, app launches, signatures or core execution."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("smoke", HERE / "test-signed-release-app.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


def pins():
    return {"schema": 1, "ready": True, "repository": smoke.REPOSITORY, "tag": "v1.0.0", "release_id": 1, "asset_id": 2,
            "archive": "OpenEmu-Reborn-universal.zip", "sha256": "a" * 64, "length": 7, "signature": "A" * 86 + "==",
            "public_key": "C1aUBkg5G0afqAq9XhxxFKaDO0PsMRAxmLkMUdKSIC4=", "certificate_sha1": "6AAC8032B0ABA0D7B731516C0384FA9CC0BFA44F",
            "architecture": "universal", "version": "1.0.0", "build": "23", "host_source_sha": "f5986815b63750d823621b45c78085797a34cfd6",
            "cores_source_sha": "425e668f329cf2fe723da84985626cbf24903724", "cores": {name: {"identifier": "org.openemu." + name, "version": "1.0"} for name in smoke.CORES},
            "helper_sha256": {name: "b" * 64 for name in smoke.HELPERS}}


def asset(p, slug=None):
    return {"id": p["asset_id"], "name": p["archive"], "size": p["length"], "digest": "sha256:" + p["sha256"], "state": "uploaded",
            "url": f"https://api.github.com/repos/{smoke.REPOSITORY}/releases/assets/{p['asset_id']}",
            "browser_download_url": f"https://github.com/{smoke.REPOSITORY}/releases/download/{slug or p['tag']}/{p['archive']}"}


def release(p, draft=True, slug=None):
    return {"id": p["release_id"], "tag_name": p["tag"], "target_commitish": p["host_source_sha"], "draft": draft, "prerelease": False,
            "html_url": f"https://github.com/{smoke.REPOSITORY}/releases/tag/{slug or p['tag']}", "assets": [asset(p, slug)]}


class Guards(unittest.TestCase):
    def test_valid_pins(self):
        smoke.validate_pins(pins())

    def test_bad_pin_fields(self):
        cases = {"ready": False, "repository": "attacker/repo", "tag": "v9.0.0", "release_id": True, "asset_id": 0,
                 "archive": "../evil.zip", "length": 5 * 1024 ** 3, "sha256": "x" * 64, "signature": "bad", "certificate_sha1": "-",
                 "public_key": "wVICc/NGoDFzkEbDb63QMFpKlRs14e/WhIiwIngQGsg=", "architecture": "arm64", "host_source_sha": "main",
                 "cores_source_sha": "missing", "version": "1.0", "build": "0", "helper_sha256": {}, "cores": {}}
        for key, value in cases.items():
            with self.subTest(key=key), self.assertRaises((ValueError, TypeError)):
                p = pins(); p[key] = value; smoke.validate_pins(p)

    def test_duplicate_json(self):
        with self.assertRaises(ValueError):
            smoke.parse_json('{"schema": 1, "schema": 2}')

    def test_assets(self):
        p = pins(); prefix = smoke.release_download_prefix(release(p), p); smoke.validate_asset(asset(p), p, prefix)
        for key, value in {"id": 5, "name": "older.zip", "size": 8, "digest": "sha256:" + "c" * 64,
                           "state": "new", "url": "https://evil.invalid/a", "browser_download_url": "https://evil.invalid/b"}.items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                a = asset(p); a[key] = value; smoke.validate_asset(a, p, prefix)

    def test_release(self):
        p = pins(); valid = release(p)
        smoke.validate_release(valid, p)
        valid["draft"] = False; smoke.validate_release(valid, p)
        for key, value in {"id": 7, "tag_name": "v2.0.0", "target_commitish": "main", "draft": None, "prerelease": True,
                           "assets": [asset(p), asset(p)]}.items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                bad = copy.deepcopy(valid); bad[key] = value; smoke.validate_release(bad, p)

    def test_untagged_draft(self):
        p = pins(); draft = release(p, slug="untagged-1234abcdef567890")
        prefix = smoke.validate_release(draft, p)
        self.assertEqual(prefix, f"https://github.com/{smoke.REPOSITORY}/releases/download/untagged-1234abcdef567890/")
        smoke.validate_asset(asset(p, "untagged-1234abcdef567890"), p, prefix)
        with self.assertRaises(ValueError): smoke.validate_asset(asset(p), p, prefix)
        draft["draft"] = False
        with self.assertRaises(ValueError): smoke.validate_release(draft, p)

    def test_hostile_release_urls(self):
        p = pins(); base = f"https://github.com/{smoke.REPOSITORY}/releases/tag/"
        values = [None, 3, {}, [], "http://github.com/" + smoke.REPOSITORY + "/releases/tag/v1.0.0",
                  "https://github.com/attacker/repo/releases/tag/v1.0.0", "https://github.com.evil.invalid/" + smoke.REPOSITORY + "/releases/tag/v1.0.0",
                  base + "v2.0.0", base + "untagged-", base + "untagged-nothex", base + "untagged-abcd/path",
                  base + "untagged-abcd?query=1", base + "untagged-abcd#fragment", base + "untagged-%61bcd",
                  base + "untagged-abcd/../v1.0.0", base + "untagged-abcd\\evil"]
        for value in values:
            with self.subTest(value=value), self.assertRaises(ValueError):
                bad = release(p); bad["html_url"] = value; smoke.validate_release(bad, p)

    def test_no_local_launch(self):
        with mock.patch.dict(smoke.os.environ, {}, clear=True), self.assertRaises(ValueError):
            smoke.validate_ci("x86_64")

    def test_canonical_owned_output(self):
        with tempfile.TemporaryDirectory(prefix="reborn-ci-path-fixture-") as directory:
            base = Path(directory).resolve(); real = base / "real"; real.mkdir()
            alias = base / "alias"; alias.symlink_to("real", target_is_directory=True)
            output = smoke.create_output(alias / "output", real)
            self.assertEqual(output, real / "output")
            self.assertEqual(output, output.resolve(strict=True))
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            with self.assertRaises(ValueError): smoke.create_output(alias / "output", real)
            with self.assertRaises(ValueError): smoke.create_output(base / "outside", real)
            (real / "linked-output").symlink_to("does-not-exist")
            with self.assertRaises(ValueError): smoke.create_output(real / "linked-output", real)

    def test_native_cpu(self):
        env = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "GITHUB_REPOSITORY": smoke.REPOSITORY,
               "RUNNER_OS": "macOS", "GH_TOKEN": "not-a-token"}
        with mock.patch.dict(smoke.os.environ, env, clear=True), mock.patch.object(smoke.platform, "machine", return_value="x86_64"):
            smoke.validate_ci("x86_64")
            with self.assertRaises(ValueError): smoke.validate_ci("arm64")

    def test_metadata(self):
        p = pins(); base = f"https://raw.githubusercontent.com/{smoke.REPOSITORY}/main/"
        info = {"CFBundleIdentifier": "org.openemu.OpenEmu", "CFBundleExecutable": "OpenEmu", "CFBundleVersion": "23",
                "CFBundleShortVersionString": "1.0.0", "SUPublicEDKey": p["public_key"], "SUFeedURL": base + "appcast.xml",
                "OECoreUpdateCatalogs": {arch: base + "Updates/cores/" + arch + "/oecores.xml" for arch in ("arm64", "x86_64")}}
        smoke.validate_app_metadata(info, p)
        for field in info:
            with self.subTest(field=field), self.assertRaises(ValueError):
                bad = copy.deepcopy(info); bad[field] = "changed"; smoke.validate_app_metadata(bad, p)

    def test_bytes_before_signature(self):
        with tempfile.TemporaryDirectory(prefix="reborn-ci-fixture-") as directory:
            archive = Path(directory) / "fixture.zip"; archive.write_bytes(b"fixture")
            p = pins(); run = mock.Mock(); smoke_root = Path(directory)
            with self.assertRaises(ValueError): smoke.authenticate_archive(archive, p, smoke_root, run)
            run.assert_not_called()
            p["sha256"] = smoke.digest(archive)
            smoke.authenticate_archive(archive, p, smoke_root, run)
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args[0][0][:2], ["xcrun", "swift"])
            run.reset_mock(); run.side_effect = RuntimeError("invalid signature")
            with self.assertRaises(RuntimeError): smoke.authenticate_archive(archive, p, smoke_root, run)

    def test_api_and_archive_calls_are_explicit_own_repo_gets(self):
        environment = {"GH_TOKEN": "fixture-token", "GH_DEBUG": "api", "GH_HOST": "wrong.invalid"}
        cases = [(f"repos/{smoke.REPOSITORY}/releases/1", "application/vnd.github+json", None),
                 (f"repos/{smoke.REPOSITORY}/releases/assets/2", "application/octet-stream", io.BytesIO())]
        for endpoint, accept, stream in cases:
            with self.subTest(endpoint=endpoint), mock.patch.object(smoke.subprocess, "run") as run:
                run.return_value = subprocess.CompletedProcess([], 0, b'{"id": 1}' if stream is None else None, b"")
                smoke.github_get(endpoint, environment, accept=accept, output=stream)
                command = run.call_args.args[0]
                self.assertEqual(command, ["gh", "api", "--hostname", "github.com", "--method", "GET", endpoint,
                                           "--header", "Accept: " + accept])
                self.assertNotIn("GH_DEBUG", run.call_args.kwargs["env"])
                self.assertEqual(run.call_args.kwargs["env"]["GH_PROMPT_DISABLED"], "1")
                self.assertEqual(run.call_args.kwargs["env"]["GH_TOKEN"], "fixture-token")
                self.assertNotIn("fixture-token", str(command))
                self.assertEqual(run.call_args.kwargs["stdout"], subprocess.PIPE if stream is None else stream)
                self.assertEqual(run.call_args.kwargs["stderr"], subprocess.PIPE)
        self.assertEqual(environment["GH_DEBUG"], "api")

    def test_api_rejects_other_paths_before_starting_gh(self):
        endpoints = ["https://evil.invalid/", "repos/attacker/repo/releases/1", f"repos/{smoke.REPOSITORY}/releases",
                     f"repos/{smoke.REPOSITORY}/releases/0", f"repos/{smoke.REPOSITORY}/releases/1?method=POST",
                     f"repos/{smoke.REPOSITORY}/releases/1/../2", f"repos/{smoke.REPOSITORY}/releases/assets/2#fragment"]
        for endpoint in endpoints:
            with self.subTest(endpoint=endpoint), mock.patch.object(smoke.subprocess, "run") as run, self.assertRaises(ValueError):
                smoke.github_get(endpoint, {"GH_TOKEN": "fixture"})
            run.assert_not_called()

    def test_api_reports_only_http_status_not_raw_diagnostics(self):
        endpoint = f"repos/{smoke.REPOSITORY}/releases/1"
        for status in (401, 403, 404, 429, 500):
            with self.subTest(status=status), mock.patch.object(smoke.subprocess, "run") as run:
                private = b"Authorization: Bearer fixture-secret\nPrivate server diagnostic body\n"
                run.return_value = subprocess.CompletedProcess([], 1, private, private + f"gh: Failed (HTTP {status})\n".encode())
                with self.assertRaises(smoke.GitHubAPIError) as raised:
                    smoke.github_get(endpoint, {"GH_TOKEN": "fixture-secret"})
                self.assertEqual(raised.exception.http_status, status)
                self.assertIn(f"HTTP {status}", str(raised.exception))
                for secret in ("fixture-secret", "Authorization", "Private server diagnostic body"):
                    self.assertNotIn(secret, str(raised.exception))
                self.assertIsNone(raised.exception.__cause__)

    def test_api_transport_and_ambiguous_status_are_not_guessed(self):
        endpoint = f"repos/{smoke.REPOSITORY}/releases/1"
        for stderr in (b"fixture-secret: connection failed", b"(HTTP 403) then (HTTP 404)"):
            with mock.patch.object(smoke.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, b"", stderr)):
                with self.assertRaises(smoke.GitHubAPIError) as raised:
                    smoke.github_get(endpoint, {})
                self.assertIsNone(raised.exception.http_status)
                self.assertNotIn("fixture-secret", str(raised.exception))

    def test_api_timeouts_and_launch_errors_hide_sensitive_context(self):
        endpoint = f"repos/{smoke.REPOSITORY}/releases/1"
        failures = [subprocess.TimeoutExpired(["gh"], 60, output=b"fixture-secret", stderr=b"Authorization: fixture-secret"),
                    OSError("fixture-secret")]
        for failure in failures:
            with mock.patch.object(smoke.subprocess, "run", side_effect=failure):
                with self.assertRaises(smoke.GitHubAPIError) as raised:
                    smoke.github_get(endpoint, {})
                self.assertIsNone(raised.exception.http_status)
                self.assertIsNone(raised.exception.__cause__)
                self.assertTrue(raised.exception.__suppress_context__)
                self.assertNotIn("fixture-secret", str(raised.exception))

    def test_helpers_and_app_do_not_inherit_github_credentials(self):
        environment = {"GH_TOKEN": "job-token", "GITHUB_TOKEN": "other-token", "GH_DEBUG": "api", "PATH": "/fixture/bin"}
        self.assertEqual(smoke.validation_environment(environment), {"PATH": "/fixture/bin"})
        self.assertEqual(environment["GH_TOKEN"], "job-token")

    def test_write_capability_is_scoped_to_same_repo_draft_check(self):
        workflow = (HERE.parents[1] / ".github/workflows/build-check.yml").read_text()
        self.assertNotIn("pull_request_target", workflow)
        prefix, job = workflow.split("\n  signed-release-app:\n", 1)
        self.assertNotIn("contents: write", prefix)
        self.assertEqual(job.count("contents: write"), 1)
        self.assertIn("github.event_name == 'pull_request'", job)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", job)
        self.assertIn("persist-credentials: false", job)
        self.assertIn("GH_TOKEN: ${{ github.token }}", job)
        self.assertNotIn("secrets.", job)


if __name__ == "__main__":
    unittest.main(verbosity=2)
