#!/usr/bin/env python3
"""Check a pinned draft/stable app ZIP on a fresh GitHub-hosted Mac; never build/sign."""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys

REPOSITORY = "communism420/OpenEmu-Reborn"
CORES = ("4DO", "Atari800", "Bliss", "BSNES", "CrabEmu", "DeSmuME", "Dolphin", "FCEU", "Flycast",
         "Gambatte", "GenesisPlus", "JollyCV", "MAME", "Mednafen", "mGBA", "Mupen64Plus", "Nestopia",
         "O2EM", "Picodrive", "PokeMini", "Potator", "PPSSPP", "ProSystem", "SNES9x", "Stella", "VecXGL",
         "VirtualJaguar", "blueMSX")
HELPERS = ("Scripts/update_archive.py", "Scripts/verify-update-signature.swift",
           "Scripts/verify-bundle-architectures.sh", "Scripts/Tests/test-data-folder-app.sh")
FIELDS = {"schema", "ready", "repository", "tag", "release_id", "asset_id", "archive", "sha256", "length",
          "signature", "public_key", "certificate_sha1", "architecture", "version", "build", "host_source_sha",
          "cores_source_sha", "cores", "helper_sha256"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def pairs(entries):
    result = {}
    for key, value in entries:
        require(key not in result, "Duplicate JSON field")
        result[key] = value
    return result


def parse_json(data):
    require(len(data) <= 2 * 1024 * 1024, "JSON exceeds safety limit")
    return json.loads(data, object_pairs_hook=pairs)


class GitHubAPIError(ValueError):
    def __init__(self, endpoint, reason, http_status=None):
        self.http_status = http_status
        # Never include gh stdout/stderr, headers or environment in diagnostics.
        status = "HTTP " + str(http_status) if http_status is not None else "HTTP status unavailable"
        super().__init__(f"GitHub GET {endpoint} failed: {reason}; {status}")


def github_get(endpoint, environment, *, accept="application/vnd.github+json", output=None, timeout=60):
    require(isinstance(endpoint, str) and re.fullmatch(
        re.escape("repos/" + REPOSITORY + "/releases/") + r"(?:assets/)?[1-9][0-9]*", endpoint),
        "Only exact own-repository release/asset GET endpoints are allowed")
    require(accept in ("application/vnd.github+json", "application/octet-stream"), "Unexpected GitHub response type")
    clean_env = environment.copy()
    clean_env.pop("GH_DEBUG", None)
    clean_env["GH_PROMPT_DISABLED"] = "1"
    command = ["gh", "api", "--hostname", "github.com", "--method", "GET", endpoint, "--header", "Accept: " + accept]
    try:
        result = subprocess.run(command, check=False, stdout=output if output is not None else subprocess.PIPE,
                                stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, timeout=timeout, env=clean_env)
    except subprocess.TimeoutExpired:
        raise GitHubAPIError(endpoint, "request timed out") from None
    except OSError:
        raise GitHubAPIError(endpoint, "could not start the GitHub client") from None
    if result.returncode != 0:
        # gh's concise error suffix contains the status. Extract only those
        # three digits; arbitrary error bodies or debug text remain private.
        statuses = set(re.findall(rb"\(HTTP ([1-5][0-9]{2})\)", (result.stderr or b"")[-16384:]))
        status = int(next(iter(statuses))) if len(statuses) == 1 else None
        raise GitHubAPIError(endpoint, "request rejected or transport failed", status)
    return result.stdout


def validation_environment(environment):
    clean = environment.copy()
    for variable in ("GH_TOKEN", "GITHUB_TOKEN", "GH_DEBUG"):
        clean.pop(variable, None)
    return clean


def validate_pins(pins):
    require(set(pins) == FIELDS and pins["schema"] == 1 and pins["ready"] is True, "Unready/unknown smoke pins")
    require(pins["repository"] == REPOSITORY and pins["architecture"] == "universal", "Unexpected repository/CPU")
    require(re.fullmatch(r"\d+\.\d+\.\d+", pins["version"]) and pins["tag"] == "v" + pins["version"], "Wrong tag/version")
    require(isinstance(pins["build"], str) and re.fullmatch(r"[1-9][0-9]*", pins["build"]), "Invalid build")
    for key in ("release_id", "asset_id", "length"):
        require(type(pins[key]) is int and pins[key] > 0, "Invalid numeric pin: " + key)
    require(pins["length"] <= 4 * 1024 ** 3, "Archive exceeds 4 GiB safety limit")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.zip", pins["archive"]), "Unsafe archive basename")
    for key, size in (("sha256", 64), ("host_source_sha", 40), ("cores_source_sha", 40), ("certificate_sha1", 40)):
        require(isinstance(pins[key], str) and re.fullmatch(r"[a-fA-F0-9]{" + str(size) + r"}", pins[key]), "Invalid pin: " + key)
    for key, size in (("public_key", 32), ("signature", 64)):
        require(isinstance(pins[key], str) and len(base64.b64decode(pins[key], validate=True)) == size, "Invalid public authentication pin")
    require(pins["public_key"] != "wVICc/NGoDFzkEbDb63QMFpKlRs14e/WhIiwIngQGsg=", "Inherited signing key forbidden")
    require(set(pins["helper_sha256"]) == set(HELPERS), "Missing/unexpected helper pins")
    require(all(re.fullmatch(r"[a-f0-9]{64}", value) for value in pins["helper_sha256"].values()), "Invalid helper digest")
    require(set(pins["cores"]) == set(CORES), "Exactly 28 native core pins required")
    for name, core in pins["cores"].items():
        require(set(core) == {"identifier", "version"} and core["identifier"].casefold() == ("org.openemu." + name).casefold()
                and isinstance(core["version"], str) and core["version"], "Invalid core metadata pin")


def validate_ci(arch):
    require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and os.environ.get("GITHUB_REPOSITORY") == REPOSITORY and os.environ.get("RUNNER_OS") == "macOS",
            "This app launch check is restricted to this repository's GitHub-hosted Macs")
    require(arch in ("arm64", "x86_64") and platform.machine() == arch, "Native runner CPU mismatch")
    require(os.environ.get("GH_TOKEN"), "Job-scoped GH_TOKEN with draft access required")


def validate_asset(asset, pins, download_prefix):
    endpoint = f"https://api.github.com/repos/{REPOSITORY}/releases/assets/{pins['asset_id']}"
    download = download_prefix + pins["archive"]
    require(type(asset.get("id")) is int and asset.get("id") == pins["asset_id"] and asset.get("name") == pins["archive"]
            and asset.get("state") == "uploaded" and type(asset.get("size")) is int and asset.get("size") == pins["length"]
            and asset.get("digest") == "sha256:" + pins["sha256"] and asset.get("url") == endpoint
            and asset.get("browser_download_url") == download, "Release asset differs from exact signed ZIP pins")


def release_download_prefix(release, pins):
    require(type(release.get("id")) is int and release.get("id") == pins["release_id"] and release.get("tag_name") == pins["tag"]
            and release.get("target_commitish") == pins["host_source_sha"]
            and type(release.get("draft")) is bool and release.get("prerelease") is False,
            "Wrong release/source/state (draft or stable allowed, prerelease forbidden)")
    # GitHub uses a generated untagged-HEX URL for a draft without an existing
    # git tag, even while tag_name is already v1.0.0. Only this exact own-repo
    # HTTPS shape is accepted; no query, fragment, encoding or redirect host.
    html_prefix = f"https://github.com/{REPOSITORY}/releases/tag/"
    html_url = release.get("html_url")
    require(isinstance(html_url, str) and html_url.startswith(html_prefix), "Wrong release HTML repository/URL")
    slug = html_url[len(html_prefix):]
    require(slug == pins["tag"] or (release["draft"] is True and re.fullmatch(r"untagged-[0-9a-f]+", slug)),
            "Unexpected draft/stable release URL path")
    return f"https://github.com/{REPOSITORY}/releases/download/{slug}/"


def validate_release(release, pins):
    prefix = release_download_prefix(release, pins)
    matches = [asset for asset in release.get("assets", []) if asset.get("id") == pins["asset_id"] or asset.get("name") == pins["archive"]]
    require(len(matches) == 1, "Pinned release lacks a unique matching asset")
    validate_asset(matches[0], pins, prefix)
    return prefix


def validate_app_metadata(info, pins):
    require(info.get("CFBundleIdentifier") == "org.openemu.OpenEmu" and info.get("CFBundleExecutable") == "OpenEmu",
            "Unexpected archived app identity")
    for field, pin in (("CFBundleVersion", "build"), ("CFBundleShortVersionString", "version"), ("SUPublicEDKey", "public_key")):
        require(info.get(field) == pins[pin], "Archived app metadata differs: " + field)
    base = f"https://raw.githubusercontent.com/{REPOSITORY}/main/"
    require(info.get("SUFeedURL") == base + "appcast.xml", "Wrong archived app feed")
    require(info.get("OECoreUpdateCatalogs") == {arch: base + "Updates/cores/" + arch + "/oecores.xml" for arch in ("arm64", "x86_64")},
            "Wrong archived architecture-specific core catalogs")


def authenticate_archive(archive, pins, root, run):
    require(not archive.is_symlink() and archive.is_file() and archive.stat().st_size == pins["length"]
            and digest(archive) == pins["sha256"], "Downloaded ZIP bytes differ from pins/API digest")
    run(["xcrun", "swift", str(root / "Scripts/verify-update-signature.swift"), str(archive), pins["public_key"], pins["signature"]],
        "signature", 180)


def create_output(output, runner_temp):
    require(not output.exists() and not output.is_symlink() and output.parent.resolve() == runner_temp.resolve(), "Choose new direct RUNNER_TEMP output")
    output.mkdir(mode=0o700)
    # GitHub can spell the same runner temp path under /var or /private/var.
    # Canonicalize only our newly created directory, before safe extraction.
    return output.resolve(strict=True)


def run_check(pins_path, output, arch, root):
    validate_ci(arch)
    pins = parse_json(pins_path.read_bytes())
    validate_pins(pins)
    output = create_output(output, Path(os.environ["RUNNER_TEMP"]))
    report = {"schema": 1, "status": "failed", "scope": "signed app startup/storage/relaunch; not gameplay or full Sparkle replacement",
              "native_architecture": arch, "pins_sha256": digest(pins_path), "host_source_sha": pins["host_source_sha"],
              "cores_source_sha": pins["cores_source_sha"], "archive_sha256": pins["sha256"], "core_builds": False, "app_build": False,
              "signing": False, "trust_changes": False, "published": False, "ci_run_id": os.environ.get("GITHUB_RUN_ID")}
    clean_env = os.environ.copy()
    clean_env.pop("GH_DEBUG", None)
    helper_env = validation_environment(clean_env)

    def run(command, label, timeout):
        with (output / (label + ".log")).open("xb") as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                           timeout=timeout, env=helper_env)

    def api(endpoint):
        return parse_json(github_get(endpoint, clean_env))

    try:
        for relative, expected in pins["helper_sha256"].items():
            require(digest(root / relative) == expected, "Reviewed helper changed: " + relative)
        source_info = plistlib.loads((root / "OpenEmu/OpenEmu-Info.plist").read_bytes())
        require(source_info.get("SUPublicEDKey") == pins["public_key"], "Pinned key differs from reviewed source")
        release = api(f"repos/{REPOSITORY}/releases/{pins['release_id']}")
        download_prefix = validate_release(release, pins)
        asset = api(f"repos/{REPOSITORY}/releases/assets/{pins['asset_id']}")
        validate_asset(asset, pins, download_prefix)
        report["release_draft_at_test"] = release["draft"]
        archive = output / pins["archive"]
        with archive.open("xb") as stream:
            github_get(f"repos/{REPOSITORY}/releases/assets/{pins['asset_id']}", clean_env,
                       accept="application/octet-stream", output=stream, timeout=900)
        # No archive inspection/extraction before both byte and Ed25519 checks.
        authenticate_archive(archive, pins, root, run)
        report["archive_authenticated_before_extraction"] = True
        spec = importlib.util.spec_from_file_location("release_archive", root / "Scripts/update_archive.py")
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        extraction = output / "extracted"
        extraction.mkdir(mode=0o700)
        app = helper.extract_app_zip(archive, extraction)
        helper.validate_app_files(app)
        validate_app_metadata(plistlib.loads((app / "Contents/Info.plist").read_bytes()), pins)
        run(["codesign", "--verify", "--deep", "--strict", str(app)], "app-codesign", 180)
        cores = app / "Contents/PlugIns/Cores"
        require(cores.is_dir() and not cores.is_symlink() and {p.name for p in cores.iterdir()} == {name + ".oecoreplugin" for name in CORES},
                "Exactly 28 bundled native core directories required")
        certificate_requirement = '=certificate leaf = H"' + pins["certificate_sha1"] + '"'
        for cpu in ("arm64", "x86_64"):
            run(["bash", str(root / "Scripts/verify-bundle-architectures.sh"), "--arch", cpu, str(app)], "all-binaries-" + cpu, 900)
            run(["codesign", "--verify", "--strict", "--architecture", cpu, "--test-requirement", certificate_requirement, str(app)],
                "app-certificate-" + cpu, 120)
        for name, expected in pins["cores"].items():
            core = cores / (name + ".oecoreplugin")
            require(core.is_dir() and not core.is_symlink(), "Core is not a real directory")
            info = plistlib.loads((core / "Contents/Info.plist").read_bytes())
            require(info.get("CFBundleIdentifier", "").casefold() == expected["identifier"].casefold()
                    and info.get("CFBundleVersion") == expected["version"], "Wrong archived core: " + name)
            run(["codesign", "--verify", "--deep", "--strict", "--test-requirement", certificate_requirement, str(core)], "core-" + name, 120)
        report["static_app_and_28_cores_verified"] = True
        # This launches the exact authenticated extracted app on a disposable CI
        # user only; original smoke script owns/cleans its processes and data.
        run(["bash", str(root / "Scripts/Tests/test-data-folder-app.sh"), str(app)], "storage-smoke", 210)
        require(digest(archive) == pins["sha256"], "Original signed ZIP changed during smoke")
        run(["codesign", "--verify", "--deep", "--strict", str(app)], "app-codesign-after-smoke", 180)
        report.update(status="passed", archive_unchanged=True, startup_storage_relaunch_passed=True)
    except Exception as error:
        report.update(error_type=type(error).__name__, error=str(error))
        if isinstance(error, GitHubAPIError):
            report["api_http_status"] = error.http_status
        raise
    finally:
        smoke_log = output / "storage-smoke.log"
        if smoke_log.is_file():
            matches = re.findall(r"^Inspection directory \(not deleted\): (/private/tmp/openemu-data-folder-app-[^\n]+)$", smoke_log.read_text(errors="replace"), re.M)
            if len(set(matches)) == 1:
                directory = Path(matches[0])
                if directory.is_dir() and not directory.is_symlink() and directory.parent == Path("/private/tmp"):
                    evidence = output / "smoke-logs"
                    evidence.mkdir()
                    for log in directory.glob("*.log"):
                        if log.is_file() and not log.is_symlink():
                            shutil.copyfile(log, evidence / log.name)
        (output / "REPORT.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print("Smoke evidence:", output / "REPORT.json", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pins", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--arch", required=True, choices=["arm64", "x86_64"])
    args = parser.parse_args()
    root = Path(os.environ.get("GITHUB_WORKSPACE", "")).resolve()
    run_check(args.pins.resolve(strict=True), args.output.absolute(), args.arch, root)


if __name__ == "__main__":
    main()
