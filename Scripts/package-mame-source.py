#!/usr/bin/env python3
"""Preserve the complete pinned MAME source and exact Reborn patch for release.

Reads committed upstream blobs, never generated build products or untracked files.
Does not change either checkout, fetch, compile, sign, install, or publish.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "communism420/OpenEmu-Reborn"
PATCH = "MAME/patches/mame-headless-clang21-apple.patch"
PIN = "MAME/deps-mame-revision.txt"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def git(repository, *args):
    return subprocess.check_output(["git", *args], cwd=repository)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_entries(source, revision):
    entries = []
    for record in git(source, "ls-tree", "-rz", revision).split(b"\0"):
        if not record:
            continue
        attributes, path_bytes = record.split(b"\t", 1)
        mode, kind, object_id = attributes.decode("ascii").split()
        path = path_bytes.decode("utf-8")
        require(kind == "blob" and mode in ("100644", "100755", "120000"),
                f"source contains an unsupported entry or unresolved submodule: {path}")
        parts = PurePosixPath(path).parts
        require(parts and not path.startswith("/") and "\\" not in path and
                all(part not in (".", "..", ".git") for part in parts), "unsafe upstream source path")
        entries.append((mode, object_id, path))
    require(entries, "pinned source tree is empty")
    return entries


def verify_applied_patch(source, revision, patch_bytes, entries):
    # This deliberately supports the repository's existing-file text patch.
    # A future patch with additions/renames needs an explicit guard update.
    old_paths = re.findall(r"^--- a/(.+)$", patch_bytes.decode("utf-8"), re.MULTILINE)
    new_paths = re.findall(r"^\+\+\+ b/(.+)$", patch_bytes.decode("utf-8"), re.MULTILINE)
    require(old_paths and old_paths == new_paths and len(set(old_paths)) == len(old_paths),
            "MAME patch must modify distinct existing files")
    changed = {path.decode("utf-8") for path in git(source, "diff", "--name-only", "-z", revision).split(b"\0") if path}
    require(changed == set(old_paths), "prepared MAME checkout has missing or unexpected tracked changes")
    require(not git(source, "diff", "--cached", "--name-only"), "MAME checkout has staged changes")
    lookup = {path: (mode, object_id) for mode, object_id, path in entries}
    with tempfile.TemporaryDirectory(prefix="openemu-mame-patch-check-") as temporary:
        staging = Path(temporary)
        expected = staging / "expected"
        expected.mkdir()
        subprocess.run(["git", "init", "-q", str(expected)], check=True)
        patch = staging / "source.patch"
        patch.write_bytes(patch_bytes)
        for path in old_paths:
            require(path in lookup and lookup[path][0] in ("100644", "100755"), "patch target is not a regular committed file")
            target = expected / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(git(source, "cat-file", "blob", lookup[path][1]))
            target.chmod(int(lookup[path][0], 8) & 0o777)
        subprocess.run(["git", "apply", "--check", str(patch)], cwd=expected, check=True)
        subprocess.run(["git", "apply", str(patch)], cwd=expected, check=True)
        for path in old_paths:
            actual = source / path
            require(actual.is_file() and not actual.is_symlink() and
                    actual.read_bytes() == (expected / path).read_bytes() and
                    bool(actual.stat().st_mode & 0o111) == bool((expected / path).stat().st_mode & 0o111),
                    f"prepared source differs from the exact Reborn patch: {path}")
    return old_paths


def add_bytes(archive, name, value, mode=0o644):
    entry = tarfile.TarInfo(name)
    entry.size = len(value)
    entry.mode = mode
    archive.addfile(entry, io.BytesIO(value))


def write_source_archive(path, source, entries, patch_bytes, metadata):
    # cat-file streams all tracked files directly from the pinned commit. Unlike
    # git archive, this also includes files marked export-ignore/export-subst.
    process = subprocess.Popen(["git", "cat-file", "--batch"], cwd=source,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        with tarfile.open(path, "w:gz", compresslevel=6) as archive:
            for mode, object_id, name in entries:
                process.stdin.write((object_id + "\n").encode("ascii"))
                process.stdin.flush()
                header = process.stdout.readline().decode("ascii").split()
                require(len(header) == 3 and header[:2] == [object_id, "blob"], "could not read pinned Git blob")
                length = int(header[2])
                entry = tarfile.TarInfo("mame/" + name)
                entry.mode = int(mode, 8) & 0o777
                if mode == "120000":
                    require(length <= 4096, "oversized source symlink")
                    target = process.stdout.read(length).decode("utf-8")
                    require(not target.startswith("/") and "\\" not in target and "\x00" not in target,
                            "unsafe source symlink")
                    normalized = os.path.normpath(str(PurePosixPath("mame/" + name).parent / target))
                    require(normalized.startswith("mame/"), "source symlink leaves the source directory")
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = target
                    archive.addfile(entry)
                else:
                    entry.size = length
                    archive.addfile(entry, process.stdout)
                require(process.stdout.read(1) == b"\n", "truncated Git blob stream")
            add_bytes(archive, "reborn/mame-headless-clang21-apple.patch", patch_bytes)
            add_bytes(archive, "SOURCE-INFO.json", (json.dumps(metadata, indent=2, sort_keys=True) + "\n").encode())
            add_bytes(archive, "README.txt", (
                "Pinned MAME source for OpenEmu Reborn\n\n"
                f"Reborn source commit: {metadata['source_sha']}\n"
                f"MAME upstream commit: {metadata['mame_upstream_revision']}\n\n"
                "mame/ contains every tracked file from that upstream commit, unchanged.\n"
                "reborn/ contains the exact patch applied before the associated CI build.\n"
                "From mame/, apply it once with:\n"
                "  git apply ../reborn/mame-headless-clang21-apple.patch\n\n"
                "Use the Reborn source archive for the same commit for the OpenEmu-SDK,\n"
                "MAME wrapper, Xcode projects and Scripts/build-mame-core.sh build commands.\n"
                "Put this patched source in that checkout's MAME/deps/mame directory.\n"
                "The normal preparation script may fetch Git metadata when it is absent;\n"
                "the complete underlying source files are included here.\n"
                "Generated binaries, object files, Git metadata and untracked files from\n"
                "the CI checkout are not included. Keep the original source notices.\n"
            ).encode())
        process.stdin.close()
        require(process.wait() == 0, "Git blob reader failed")
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait()
        process.stdout.close()
        if not process.stdin.closed:
            process.stdin.close()


def package(args):
    require(re.fullmatch(r"[0-9a-f]{40}", args.source_sha), "source SHA must be a full commit ID")
    require(git(ROOT, "rev-parse", "HEAD").decode().strip() == args.source_sha, "Reborn checkout does not match source SHA")
    pinned_bytes = git(ROOT, "show", f"{args.source_sha}:{PIN}")
    patch_bytes = git(ROOT, "show", f"{args.source_sha}:{PATCH}")
    require((ROOT / PATCH).read_bytes() == patch_bytes and (ROOT / PIN).read_bytes() == pinned_bytes,
            "MAME pin or patch differs from the source commit")
    match = re.search(rb"commit:\s*([0-9a-f]{40})", pinned_bytes)
    require(match is not None, "missing pinned MAME revision")
    revision = match[1].decode("ascii")
    source = args.mame_source.resolve(strict=True)
    require(git(source, "rev-parse", "HEAD").decode().strip() == revision, "MAME checkout does not match the pinned revision")
    destination = args.output.absolute()
    require(not destination.exists() and not destination.is_symlink(), "output must be a new directory")
    destination = destination.resolve()
    require(source != destination and source not in destination.parents, "output must be outside the MAME checkout")
    entries = tree_entries(source, revision)
    changed = verify_applied_patch(source, revision, patch_bytes, entries)
    archive_name = f"MAME-source-{args.source_sha[:12]}.tar.gz"
    metadata = {"schema": 1, "kind": "mame-source", "source_repository": REPOSITORY,
                "source_sha": args.source_sha, "mame_upstream_repository": "https://github.com/stuartcarnie/mame.git",
                "mame_upstream_revision": revision, "mame_patch_sha256": hashlib.sha256(patch_bytes).hexdigest(),
                "patch_paths": changed, "tracked_source_files": len(entries), "archive": archive_name,
                "source_layout": "unmodified pinned upstream tree plus exact Reborn patch",
                "workflow_run_id": os.environ.get("GITHUB_RUN_ID", ""),
                "workflow_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "")}
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".openemu-mame-source-", dir=destination.parent) as temporary:
        prepared = Path(temporary) / "prepared"
        prepared.mkdir()
        archive = prepared / archive_name
        write_source_archive(archive, source, entries, patch_bytes, metadata)
        # Re-read the finished archive and compare the complete path inventory.
        with tarfile.open(archive, "r:gz") as source_archive:
            found = set()
            for member in source_archive:
                require(member.name not in found, "duplicate source archive entry")
                found.add(member.name)
                if member.isfile():
                    with source_archive.extractfile(member) as stream:
                        while stream.read(1024 * 1024):
                            pass
            expected = {"mame/" + name for _, _, name in entries} | {
                "reborn/mame-headless-clang21-apple.patch", "SOURCE-INFO.json", "README.txt"}
            require(found == expected, "source archive is missing committed files")
        metadata.update(archive_sha256=sha256(archive), archive_size=archive.stat().st_size)
        (prepared / "SOURCE-INFO.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
        (prepared / "SHA256SUMS").write_text(f"{metadata['archive_sha256']}  {archive_name}\n")
        os.replace(prepared, destination)
    print(f"Preserved {len(entries)} pinned MAME source files plus the exact patch: {destination / archive_name}")
    print("No source checkout was modified and no build, signing or publication was performed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--mame-source", type=Path, default=ROOT / "MAME/deps/mame")
    parser.add_argument("--output", required=True, type=Path)
    try:
        package(parser.parse_args())
    except (ValueError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
