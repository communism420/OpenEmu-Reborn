#!/usr/bin/env python3
"""Preserve a verified CI Release bundle and its source/build metadata.

This packages an existing build. It never builds, signs, installs, or publishes.
The archive remains unsigned; release publication must authenticate it separately.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import zipfile


ROOT = Path(__file__).resolve().parent.parent


def output(*command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_metadata(expected_sha, kind, name):
    revision = output("git", "rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", expected_sha) or revision != expected_sha:
        raise ValueError("source SHA must match the exact checked-out commit")

    # CI removes the host entry from the combined scheme, and DeSmuME's build
    # generates its tracked revision header. Record those exact generated files;
    # unexpected tracked source changes must not be attributed to the commit.
    allowed = set()
    if kind == "core":
        allowed.add(f"OpenEmu-metal.xcworkspace/xcshareddata/xcschemes/OpenEmu + {name}.xcscheme")
        if name == "DeSmuME":
            allowed.add("DeSmuME/src/scmrev.h")
    changed = set(output("git", "diff", "--name-only", "HEAD").splitlines())
    if changed - allowed:
        raise ValueError("unexpected tracked source changes: " + ", ".join(sorted(changed - allowed)))
    generated = {path: sha256(ROOT / path) for path in sorted(changed)}
    return revision, generated


def package(args):
    if not re.fullmatch(r"[A-Za-z0-9]+", args.name):
        raise ValueError("artifact name must contain only letters and digits")
    if args.kind == "host" and args.name != "OpenEmu":
        raise ValueError("host artifact must be named OpenEmu")
    if args.arch == "universal" and args.kind != "host":
        raise ValueError("universal CI artifacts are supported only for the host app")
    extension = ".app" if args.kind == "host" else ".oecoreplugin"
    bundle = args.bundle.resolve(strict=True)
    if not bundle.is_dir() or bundle.name != args.name + extension:
        raise ValueError("bundle name does not match the requested artifact")
    destination = args.output.resolve()
    if destination.exists() or bundle == destination or bundle in destination.parents:
        raise ValueError("output must be a new directory outside the input bundle")

    revision, generated = source_metadata(args.source_sha, args.kind, args.name)
    info_bytes = (bundle / "Contents/Info.plist").read_bytes()
    info = plistlib.loads(info_bytes)
    for key in ("CFBundleIdentifier", "CFBundleVersion", "CFBundleExecutable"):
        if not isinstance(info.get(key), str) or not info[key]:
            raise ValueError(f"bundle is missing {key}")
    executable = info["CFBundleExecutable"]
    if Path(executable).name != executable or executable in (".", ".."):
        raise ValueError("invalid bundle executable name")
    if not (bundle / "Contents/MacOS" / executable).is_file():
        raise ValueError("bundle executable is missing")

    architectures = ("arm64", "x86_64") if args.arch == "universal" else (args.arch,)
    for architecture in architectures:
        subprocess.run([str(ROOT / "Scripts/verify-bundle-architectures.sh"),
                        "--arch", architecture, str(bundle)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)

    destination.mkdir(parents=True, exist_ok=False)
    archive = destination / f"{args.name}-{args.arch}{extension}.zip"
    subprocess.run(["ditto", "-c", "-k", "--keepParent", "--norsrc",
                    str(bundle), str(archive)], check=True)
    with zipfile.ZipFile(archive) as zipped:
        if zipped.testzip() is not None:
            raise ValueError("archive failed its CRC check")
        if zipped.read(f"{bundle.name}/Contents/Info.plist") != info_bytes:
            raise ValueError("archived bundle metadata differs from the input")

    metadata = {
        "schema": 1,
        "kind": args.kind,
        "name": args.name,
        "source_repository": os.environ.get("GITHUB_REPOSITORY", ""),
        "source_sha": revision,
        "generated_tracked_files_sha256": generated,
        "configuration": "Release",
        "architecture": args.arch,
        "bundle_identifier": info["CFBundleIdentifier"],
        "bundle_version": info["CFBundleVersion"],
        "bundle_short_version": info.get("CFBundleShortVersionString", ""),
        "archive": archive.name,
        "archive_sha256": sha256(archive),
        "archive_size": archive.stat().st_size,
        "archive_signed": False,
        "checks": ["bundle-architecture", "codesign-deep-strict", "zip-crc", "archived-info-plist"],
        "workflow_run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "workflow_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
        "runner_image": os.environ.get("ImageOS", ""),
        "runner_image_version": os.environ.get("ImageVersion", ""),
        "xcode": output("xcodebuild", "-version"),
    }
    if args.name == "MAME" and args.kind == "core":
        pinned = (ROOT / "MAME/deps-mame-revision.txt").read_text()
        match = re.search(r"commit:\s*([0-9a-f]{40})", pinned)
        actual = output("git", "-C", str(ROOT / "MAME/deps/mame"), "rev-parse", "HEAD")
        if match is None or actual != match[1]:
            raise ValueError("MAME source does not match the pinned upstream revision")
        metadata["mame_upstream_revision"] = actual
        metadata["mame_patch_sha256"] = sha256(ROOT / "MAME/patches/mame-headless-clang21-apple.patch")
    with (destination / "BUILD-INFO.json").open("x") as stream:
        json.dump(metadata, stream, indent=2, sort_keys=True)
        stream.write("\n")
    print(f"Preserved {args.kind} {args.name} ({args.arch}) from {revision}: {archive}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", required=True, choices=("core", "host"))
    parser.add_argument("--name", required=True)
    parser.add_argument("--arch", required=True, choices=("arm64", "x86_64", "universal"),
                        help="universal is permitted only with --kind host")
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        package(args)
    except (ValueError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
