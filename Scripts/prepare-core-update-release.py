#!/usr/bin/env python3
"""Validate 56 CI core archives and prepare a signed, unpublished Reborn catalog.

No core is built, installed, or modified. Only original archive bytes are signed.
Publish the prepared assets before copying the generated Updates tree into source.
"""

import argparse
import base64
import copy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "communism420/OpenEmu-Reborn"
ARCHITECTURES = ("arm64", "x86_64")
CORES = ("4DO", "Atari800", "Bliss", "BSNES", "CrabEmu", "DeSmuME", "Dolphin",
         "FCEU", "Flycast", "Gambatte", "GenesisPlus", "JollyCV", "MAME", "Mednafen",
         "mGBA", "Mupen64Plus", "Nestopia", "O2EM", "Picodrive", "PokeMini", "Potator",
         "PPSSPP", "ProSystem", "SNES9x", "Stella", "VecXGL", "VirtualJaguar", "blueMSX")
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MAXIMUM_ARCHIVE_LENGTH = 1_073_741_824  # OECoreUpdateSecurity.maximumArchiveLength
ET.register_namespace("sparkle", SPARKLE)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def public_key(value):
    try:
        require(len(base64.b64decode(value, validate=True)) == 32, "public key must be 32 bytes")
    except (ValueError, TypeError) as error:
        raise ValueError("invalid base64 Ed25519 public key") from error
    return value


def read_catalog(source_sha):
    require(re.fullmatch(r"[0-9a-f]{40}", source_sha), "source SHA must be a full commit ID")
    source = subprocess.check_output(["git", "show", f"{source_sha}:oecores.xml"], cwd=ROOT)
    catalog = ET.fromstring(source)
    entries = catalog.findall("core")
    expected = {f"org.openemu.{name}".casefold() for name in CORES}
    ids = [entry.get("id", "").casefold() for entry in entries]
    require(len(entries) == 28 and len(set(ids)) == 28 and set(ids) == expected,
            "source catalog must contain exactly the 28 expected native identifiers")
    return catalog


def source_public_key(source_sha):
    require(re.fullmatch(r"[0-9a-f]{40}", source_sha), "source SHA must be a full commit ID")
    source = subprocess.check_output(
        ["git", "show", f"{source_sha}:OpenEmu/OpenEmu-Info.plist"], cwd=ROOT)
    return public_key(plistlib.loads(source).get("SUPublicEDKey"))


def validate_metadata(directory, core, arch, source_sha):
    require(directory.is_dir() and not directory.is_symlink(), f"missing artifact directory: {directory}")
    metadata_path = directory / "BUILD-INFO.json"
    require(metadata_path.is_file() and not metadata_path.is_symlink(), "missing regular BUILD-INFO.json")
    metadata = json.loads(metadata_path.read_text())
    archive_name = f"{core}-{arch}.oecoreplugin.zip"
    expected = {"schema": 1, "kind": "core", "name": core, "architecture": arch,
                "source_sha": source_sha, "source_repository": REPOSITORY,
                "configuration": "Release", "archive": archive_name, "archive_signed": False}
    for key, value in expected.items():
        require(metadata.get(key) == value, f"{directory.name}: incorrect {key}")
    require(str(metadata.get("workflow_run_id", "")).isdigit() and
            int(metadata["workflow_run_id"]) > 0, "missing workflow run provenance")
    require(str(metadata.get("workflow_run_attempt", "")).isdigit() and
            int(metadata["workflow_run_attempt"]) > 0, "missing workflow attempt provenance")
    require(metadata.get("bundle_identifier", "").casefold() == f"org.openemu.{core}".casefold(),
            "artifact bundle identifier does not match the expected core")
    require(isinstance(metadata.get("bundle_version"), str) and metadata["bundle_version"],
            "missing bundle version")
    generated = metadata.get("generated_tracked_files_sha256")
    allowed = {f"OpenEmu-metal.xcworkspace/xcshareddata/xcschemes/OpenEmu + {core}.xcscheme"}
    if core == "DeSmuME":
        allowed.add("DeSmuME/src/scmrev.h")
    require(isinstance(generated, dict) and set(generated) <= allowed,
            "unexpected generated source files in artifact provenance")
    require(all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value)
                for value in generated.values()), "invalid generated source digest")
    require({"bundle-architecture", "codesign-deep-strict", "zip-crc", "archived-info-plist"}
            <= set(metadata.get("checks", [])), "incomplete CI verification record")
    archive = directory / archive_name
    require(archive.is_file() and not archive.is_symlink(), "missing regular core archive")
    require(set(path.name for path in directory.iterdir()) == {"BUILD-INFO.json", archive_name},
            f"unexpected files in artifact directory: {directory}")
    require(type(metadata.get("archive_size")) is int and
            0 < metadata["archive_size"] <= MAXIMUM_ARCHIVE_LENGTH and
            0 < archive.stat().st_size <= MAXIMUM_ARCHIVE_LENGTH,
            "compressed core archive exceeds the runtime 1 GiB limit or has an invalid size")
    require(archive.stat().st_size == metadata["archive_size"],
            "archive size differs from CI metadata")
    require(digest(archive) == metadata.get("archive_sha256"), "archive SHA-256 differs from CI metadata")
    return archive, metadata


def safe_extract(archive, destination, bundle_name):
    """Extract regular entries before links; no writes ever pass through a link."""
    destination = destination.resolve()
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        require(entries and len(entries) <= 100000, "empty or excessive archive entry count")
        require(sum(entry.file_size for entry in entries) <= 4 * 1024 ** 3, "archive expands beyond 4 GiB")
        paths, links = {}, {}
        folded = set()
        for entry in entries:
            require(entry.orig_filename == entry.filename, "ambiguous ZIP filename")
            raw = entry.filename.rstrip("/")
            path = PurePosixPath(raw)
            require(raw and "\\" not in raw and "\x00" not in raw and ":" not in raw and
                    not path.is_absolute() and all(part not in ("", ".", "..") for part in raw.split("/")),
                    f"unsafe ZIP path: {entry.filename}")
            require(path.parts[0] == bundle_name, "archive must contain only the expected core bundle")
            require(raw.casefold() not in folded, f"duplicate ZIP path: {raw}")
            folded.add(raw.casefold())
            mode = entry.external_attr >> 16
            file_type = stat.S_IFMT(mode)
            require(file_type in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK), "unsupported ZIP file type")
            paths[path] = (entry, mode)
            if file_type == stat.S_IFLNK:
                require(entry.file_size <= 4096, "excessive symlink target")
                target = zipped.read(entry).decode("utf-8")
                require(target and not PurePosixPath(target).is_absolute() and
                        "\\" not in target and "\x00" not in target and ":" not in target,
                        "unsafe symlink target")
                resolved = os.path.normpath(str(path.parent / target))
                require(resolved == bundle_name or resolved.startswith(bundle_name + "/"),
                        "symlink target leaves its bundle")
                links[path] = target
        for path in paths:
            require(not any(parent in links for parent in path.parents), "archive writes beneath a symlink")
        for path, (entry, mode) in paths.items():
            if path in links:
                continue
            target = destination.joinpath(*path.parts)
            if entry.is_dir() or stat.S_ISDIR(mode):
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with zipped.open(entry) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(mode & 0o777 if mode & 0o777 else 0o644)
        for path, target in links.items():
            link = destination.joinpath(*path.parts)
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(target)
        bundle = destination / bundle_name
        for path in links:
            try:
                resolved = destination.joinpath(*path.parts).resolve(strict=True)
            except (OSError, RuntimeError) as error:
                raise ValueError("dangling or cyclic archive symlink") from error
            require(resolved == bundle or bundle in resolved.parents, "resolved symlink leaves its bundle")
        return bundle


def verify_archive(archive, metadata, temporary):
    bundle = safe_extract(archive, temporary, f"{metadata['name']}.oecoreplugin")
    info_path = bundle / "Contents/Info.plist"
    require(info_path.stat().st_size <= 1024 * 1024, "core Info.plist exceeds 1 MiB")
    info = plistlib.loads(info_path.read_bytes())
    require(info.get("CFBundleIdentifier", "").casefold() == metadata["bundle_identifier"].casefold(),
            "archived bundle identifier differs from CI metadata")
    require(info.get("CFBundleVersion") == metadata["bundle_version"], "archived bundle version mismatch")
    require(info.get("CFBundleShortVersionString", "") == metadata.get("bundle_short_version", ""),
            "archived short version mismatch")
    executable = info.get("CFBundleExecutable", "")
    require(executable and Path(executable).name == executable and executable not in (".", ".."),
            "invalid bundle executable")
    require((bundle / "Contents/MacOS" / executable).is_file(), "missing core executable")
    subprocess.run(["bash", str(ROOT / "Scripts/verify-bundle-architectures.sh"),
                    "--arch", metadata["architecture"], str(bundle)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    minimum = info.get("LSMinimumSystemVersion", "11.0")
    require(isinstance(minimum, str) and re.fullmatch(r"\d+(?:\.\d+){0,2}", minimum),
            "invalid minimum macOS version")
    if tuple(map(int, minimum.split("."))) < (11, 0):
        minimum = "11.0"
    return minimum


def validate_artifacts(artifacts, source_sha):
    expected = {f"reborn-core-{core}-{arch}" for core in CORES for arch in ARCHITECTURES}
    found = {path.name for path in artifacts.iterdir() if path.name.startswith("reborn-core-")}
    require(found == expected, f"complete 56-artifact set required; missing={sorted(expected-found)}, extra={sorted(found-expected)}")
    validated = []
    for core in CORES:
        versions = set()
        for arch in ARCHITECTURES:
            archive, metadata = validate_metadata(artifacts / f"reborn-core-{core}-{arch}", core, arch, source_sha)
            with tempfile.TemporaryDirectory(prefix="openemu-core-verify-") as temporary:
                minimum = verify_archive(archive, metadata, Path(temporary))
            require(digest(archive) == metadata["archive_sha256"], "archive changed during verification")
            validated.append({"archive_path": archive, "metadata": metadata, "minimum_system_version": minimum})
            versions.add(metadata["bundle_version"])
        require(len(versions) == 1, f"{core}: both architectures must have the same core version")
    return validated


def sign_archive(archive, metadata, args, verifier):
    require(digest(archive) == metadata["archive_sha256"], "archive changed before signing")
    result = subprocess.run([str(args.sign_tool), "--account", args.account, str(archive)],
                            capture_output=True, text=True, check=True)
    signatures = re.findall(r'sparkle:edSignature="([^"]+)"', result.stdout)
    lengths = re.findall(r'length="([0-9]+)"', result.stdout)
    require(len(signatures) == 1 and len(lengths) == 1 and int(lengths[0]) == metadata["archive_size"],
            "Sparkle signature output has missing or inconsistent metadata")
    require(len(base64.b64decode(signatures[0], validate=True)) == 64, "invalid Ed25519 signature size")
    subprocess.run([str(verifier), str(archive), args.public_key, signatures[0]], check=True)
    require(digest(archive) == metadata["archive_sha256"], "archive changed while signing")
    return signatures[0]


def write_xml(path, root):
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(root, space="  ")
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)


def render_catalogs(destination, catalog, validated, tag):
    for arch in ARCHITECTURES:
        directory = destination / "Updates/cores" / arch
        current = copy.deepcopy(catalog)
        current.set("architecture", arch)
        current.set("schema", "1")
        for entry in current.findall("core"):
            slug = entry.get("id").rsplit(".", 1)[1].lower()
            entry.set("appcastURL", f"https://raw.githubusercontent.com/{REPOSITORY}/main/Updates/cores/{arch}/{slug}.xml")
            entry.set("hardwareRequirements", arch)
        write_xml(directory / "oecores.xml", current)
    for record in validated:
        meta = record["metadata"]
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = f"OpenEmu Reborn — {meta['name']} ({meta['architecture']})"
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = f"{meta['name']} {meta['bundle_version']}"
        ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = record["minimum_system_version"]
        ET.SubElement(item, f"{{{SPARKLE}}}hardwareRequirements").text = meta["architecture"]
        ET.SubElement(item, "enclosure", {
            "url": f"https://github.com/{REPOSITORY}/releases/download/{tag}/{meta['archive']}",
            "length": str(meta["archive_size"]), "type": "application/octet-stream",
            f"{{{SPARKLE}}}version": meta["bundle_version"],
            f"{{{SPARKLE}}}shortVersionString": meta.get("bundle_short_version") or meta["bundle_version"],
            f"{{{SPARKLE}}}edSignature": record["signature"],
            f"{{{SPARKLE}}}hardwareRequirements": meta["architecture"],
        })
        write_xml(destination / "Updates/cores" / meta["architecture"] / f"{meta['name'].lower()}.xml", root)


def prepare(args):
    args.public_key = public_key(args.public_key)
    require(args.public_key == source_public_key(args.source_sha),
            "public key does not match SUPublicEDKey in the exact source revision")
    require(re.fullmatch(r"cores-reborn-v[0-9]+\.[0-9]+\.[0-9]+(?:[.-][A-Za-z0-9]+)*", args.tag), "invalid Reborn core release tag")
    require(args.account == "org.openemu.Reborn.updates", "use the explicit Reborn signing account")
    require(args.sign_tool.is_file() and os.access(args.sign_tool, os.X_OK), "Sparkle signing tool is not executable")
    destination = args.output.absolute()
    require(not destination.is_symlink() and (not destination.exists() or
            (destination.is_dir() and not any(destination.iterdir()))), "output must be a new or empty directory")
    destination = destination.resolve()
    if destination == ROOT or ROOT in destination.parents:
        require(subprocess.run(["git", "check-ignore", "-q", str(destination)], cwd=ROOT).returncode == 0,
                "repository output must be gitignored; do not write live feeds directly")
    catalog = read_catalog(args.source_sha)
    validated = validate_artifacts(args.artifacts_dir.resolve(strict=True), args.source_sha)
    # No signing account is accessed until every artifact has passed validation.
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".openemu-core-release-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        verifier = staging / "verify-update-signature"
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(staging / "ModuleCache"),
                        str(ROOT / "Scripts/verify-update-signature.swift"), "-o", str(verifier)], check=True)
        prepared = staging / "prepared"
        assets = prepared / "assets"
        assets.mkdir(parents=True)
        manifest = {"schema": 1, "repository": REPOSITORY, "source_sha": args.source_sha,
                    "tag": args.tag, "public_key": args.public_key, "published": False, "cores": []}
        for record in validated:
            archive, meta = record["archive_path"], record["metadata"]
            record["signature"] = sign_archive(archive, meta, args, verifier)
            copied = assets / archive.name
            shutil.copyfile(archive, copied)
            require(digest(copied) == meta["archive_sha256"], "prepared asset differs from validated archive")
            manifest["cores"].append({**meta, "archive_signed": True, "ed_signature": record["signature"],
                                      "minimum_system_version": record["minimum_system_version"]})
        render_catalogs(prepared, catalog, validated, args.tag)
        (prepared / "release-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        (prepared / "SHA256SUMS").write_text("".join(
            f"{digest(path)}  assets/{path.name}\n" for path in sorted(assets.iterdir())))
        os.replace(prepared, destination)
    print(f"Prepared 56 signed core archives and both architecture catalogs in {destination}")
    print("Not published. Upload exact assets and verify public bytes before installing the Updates tree into source.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts-dir", required=True, type=Path)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--public-key", required=True)
    parser.add_argument("--sign-tool", required=True, type=Path)
    parser.add_argument("--account", required=True)
    parser.add_argument("--output", required=True, type=Path)
    try:
        prepare(parser.parse_args())
    except (ValueError, TypeError, OSError, KeyError, ET.ParseError, zipfile.BadZipFile,
            subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
