#!/usr/bin/env python3
"""Small offline source-preservation fixtures; no MAME build or publication."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "package_mame_source", Path(__file__).resolve().parents[1] / "package-mame-source.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SourcePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="openemu-mame-source-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "upstream"
        self.reborn = self.root / "reborn"
        for repository in (self.source, self.reborn):
            repository.mkdir()
            self.git(repository, "init", "-q")
        self.original = b"int original = 1;\n"
        self.patched = b"int original = 2;\n"
        (self.source / "source.c").write_bytes(self.original)
        (self.source / "LICENSE").write_text("Original fixture notices, preserved exactly.\n")
        (self.source / ".gitattributes").write_text("included.txt export-ignore\n")
        (self.source / "included.txt").write_text("A full source snapshot must include this file.\n")
        (self.source / "configure").write_text("#!/bin/sh\nexit 0\n")
        (self.source / "configure").chmod(0o755)
        (self.source / "source-link").symlink_to("source.c")
        self.commit(self.source)
        self.upstream_sha = self.git(self.source, "rev-parse", "HEAD").decode().strip()
        (self.source / "source.c").write_bytes(self.patched)
        self.patch_bytes = self.git(self.source, "diff", "--", "source.c")
        patch_path = self.reborn / MODULE.PATCH
        patch_path.parent.mkdir(parents=True)
        patch_path.write_bytes(self.patch_bytes)
        (self.reborn / MODULE.PIN).write_text(
            f"stuartcarnie/mame commit: {self.upstream_sha}\n"
            "source: https://github.com/stuartcarnie/mame.git\n")
        self.commit(self.reborn)
        self.source_sha = self.git(self.reborn, "rev-parse", "HEAD").decode().strip()
        self.args = argparse.Namespace(source_sha=self.source_sha, mame_source=self.source,
                                       output=self.root / "output")
        self.root_patch = patch.object(MODULE, "ROOT", self.reborn)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)

    @staticmethod
    def git(repository, *args):
        return subprocess.check_output(["git", *args], cwd=repository)

    def commit(self, repository):
        self.git(repository, "add", ".")
        self.git(repository, "-c", "user.name=Source Fixture", "-c",
                 "user.email=source-fixture@example.invalid", "-c", "commit.gpgsign=false",
                 "commit", "-qm", "Source fixture")

    def test_complete_source_and_exact_patch_are_preserved_without_generated_files(self):
        (self.source / "untracked-build.dylib").write_bytes(b"not a build; exclusion fixture")
        (self.source / "untracked-secret.txt").write_text("not a secret; exclusion fixture")
        before = self.git(self.source, "status", "--porcelain")
        MODULE.package(self.args)
        self.assertEqual(self.git(self.source, "status", "--porcelain"), before)
        info = json.loads((self.args.output / "SOURCE-INFO.json").read_text())
        archive = self.args.output / info["archive"]
        self.assertEqual(info["source_sha"], self.source_sha)
        self.assertEqual(info["mame_upstream_revision"], self.upstream_sha)
        self.assertEqual(info["mame_patch_sha256"], hashlib.sha256(self.patch_bytes).hexdigest())
        self.assertEqual(info["tracked_source_files"], 6)
        self.assertEqual(info["archive_size"], archive.stat().st_size)
        self.assertEqual(info["archive_sha256"], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertEqual((self.args.output / "SHA256SUMS").read_text(),
                         f"{info['archive_sha256']}  {archive.name}\n")
        with tarfile.open(archive) as content:
            self.assertEqual(set(content.getnames()), {
                "mame/.gitattributes", "mame/LICENSE", "mame/included.txt", "mame/configure",
                "mame/source.c", "mame/source-link", "reborn/mame-headless-clang21-apple.patch",
                "SOURCE-INFO.json", "README.txt"})
            self.assertEqual(content.extractfile("mame/source.c").read(), self.original)
            self.assertEqual(content.extractfile("mame/LICENSE").read(), (self.source / "LICENSE").read_bytes())
            self.assertEqual(content.extractfile("reborn/mame-headless-clang21-apple.patch").read(), self.patch_bytes)
            self.assertEqual(content.getmember("mame/configure").mode, 0o755)
            link = content.getmember("mame/source-link")
            self.assertTrue(link.issym())
            self.assertEqual(link.linkname, "source.c")
            inner_info = json.load(content.extractfile("SOURCE-INFO.json"))
            self.assertEqual(inner_info["mame_upstream_revision"], info["mame_upstream_revision"])
            # Reapply only the fixture's archived patch to its archived original.
            restored = self.root / "restored"
            restored.mkdir()
            (restored / "source.c").write_bytes(content.extractfile("mame/source.c").read())
            saved_patch = self.root / "saved.patch"
            saved_patch.write_bytes(content.extractfile("reborn/mame-headless-clang21-apple.patch").read())
            self.git(restored, "init", "-q")
            self.git(restored, "apply", str(saved_patch))
            self.assertEqual((restored / "source.c").read_bytes(), self.patched)

    def test_reborn_source_sha_must_match(self):
        self.args.source_sha = "a" * 40
        with self.assertRaisesRegex(ValueError, "Reborn checkout does not match"):
            MODULE.package(self.args)
        self.assertFalse(self.args.output.exists())

    def test_upstream_sha_must_match_pin(self):
        self.commit(self.source)
        with self.assertRaisesRegex(ValueError, "does not match the pinned revision"):
            MODULE.package(self.args)
        self.assertFalse(self.args.output.exists())

    def test_pin_and_patch_must_match_reborn_commit(self):
        with (self.reborn / MODULE.PATCH).open("ab") as stream:
            stream.write(b"\n")
        with self.assertRaisesRegex(ValueError, "pin or patch differs"):
            MODULE.package(self.args)
        self.assertFalse(self.args.output.exists())

    def test_unexpected_tracked_source_changes_rejected(self):
        (self.source / "LICENSE").write_text("unexpected modification\n")
        with self.assertRaisesRegex(ValueError, "unexpected tracked changes"):
            MODULE.package(self.args)
        self.assertFalse(self.args.output.exists())

    def test_additional_changes_in_patch_target_rejected(self):
        (self.source / "source.c").write_bytes(self.patched + b"extra change\n")
        with self.assertRaisesRegex(ValueError, "differs from the exact Reborn patch"):
            MODULE.package(self.args)
        self.assertFalse(self.args.output.exists())

    def test_unapplied_patch_rejected(self):
        (self.source / "source.c").write_bytes(self.original)
        with self.assertRaisesRegex(ValueError, "missing or unexpected tracked changes"):
            MODULE.package(self.args)
        self.assertFalse(self.args.output.exists())

    def test_existing_output_is_never_overwritten(self):
        self.args.output.mkdir()
        sentinel = self.args.output / "keep"
        sentinel.write_text("keep")
        with self.assertRaisesRegex(ValueError, "new directory"):
            MODULE.package(self.args)
        self.assertEqual(sentinel.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
