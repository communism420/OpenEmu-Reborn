#!/usr/bin/env python3
"""Select prior core CI evidence for one narrowly scoped host-test repair.

Read-only: no downloads, builds, signing, Git writes or metadata rewriting.
This is NOT archive authentication or a release approval. Original ZIP hashes,
bundle CPUs/versions, signatures and corresponding sources still need independent
validation before publication. The current workflow and this policy are reviewed
source code, not an authority independent of the pull request containing them.
Unsupported changes, stale evidence and API failures return reuse=false (exit 0).
"""

import argparse
import copy
import json
from pathlib import Path
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
REFERENCE = {
    "schema": 1, "repository": "communism420/OpenEmu-Reborn", "repository_id": 1352454071,
    "run_id": 34286736725, "source_sha": "425e668f329cf2fe723da84985626cbf24903724",
    "source_tree": "764bbb451e95f794d19477cdbbc62650836e7320",
    "head_sha": "703e4b4d03e6327deb21a0a4378230cdfcffe7ab",
    "base_sha": "6da77e890b67fd5404d729206171e0e8c6a486b4",
    "workflow_path": ".github/workflows/build-check.yml",
}
CORES = ("4DO Atari800 Bliss BSNES CrabEmu DeSmuME Dolphin FCEU Flycast Gambatte "
         "GenesisPlus JollyCV MAME Mednafen mGBA Mupen64Plus Nestopia O2EM Picodrive "
         "PokeMini Potator PPSSPP ProSystem SNES9x Stella VecXGL VirtualJaguar blueMSX").split()
ARCHITECTURES = ("arm64", "x86_64")
SCHEME = "OpenEmu/OpenEmu.xcodeproj/xcshareddata/xcschemes/OpenEmu.xcscheme"
# Exact files only. Neither JSON configuration nor caller input can add paths.
# In particular: no SDK, core, project.pbxproj, general Scripts/** or Updates/**.
ALLOWED_CHANGES = frozenset({
    "OpenEmu/AppDelegate.swift", "OpenEmu/OEDataFolderSetup.swift",
    "OpenEmu/OpenEmuTests/ImportFailureTests.swift", SCHEME,
    ".github/workflows/build-check.yml", ".github/core-artifact-reuse.json",
    "Scripts/check-core-artifact-reuse.py", "Scripts/Tests/test-core-artifact-reuse.py",
    "docs/update-publication.md",
})


def require(condition, message):
    if not condition:
        raise ValueError(message)


def positive_integer(value):
    return type(value) is int and value > 0


def check_reference(reference):
    require(type(reference) is dict and reference == REFERENCE and
            all(type(reference[key]) is type(value) for key, value in REFERENCE.items()),
            "reuse reference differs from the reviewed fixed run/source")


def xml_shape(element):
    return (element.tag, tuple(sorted(element.attrib.items())), (element.text or "").strip(),
            tuple(xml_shape(child) for child in element))


def check_scheme(before, after):
    old, new = ET.fromstring(before), ET.fromstring(after)
    old_actions, new_actions = old.findall("TestAction"), new.findall("TestAction")
    require(len(old_actions) == len(new_actions) == 1, "expected one TestAction in host scheme")
    old_test, new_test = old_actions[0], new_actions[0]
    old.remove(old_test)
    new.remove(new_test)
    require(xml_shape(old) == xml_shape(new), "host scheme changed outside TestAction")
    old_test, new_test = copy.deepcopy(old_test), copy.deepcopy(new_test)
    old_flag = old_test.attrib.pop("shouldUseLaunchSchemeArgsEnv", None)
    new_flag = new_test.attrib.pop("shouldUseLaunchSchemeArgsEnv", None)
    require(old_flag == "YES" and new_flag in ("YES", "NO"), "unexpected test launch inheritance change")
    old_args, new_args = old_test.findall("CommandLineArguments"), new_test.findall("CommandLineArguments")
    require(not old_args and len(new_args) <= 1, "unexpected test arguments structure")
    if new_args:
        arguments = new_args[0]
        require(not arguments.attrib and len(arguments) == 2 and all(
            item.tag == "CommandLineArgument" and not list(item) and item.attrib in (
                {"argument": "-SUEnableAutomaticChecks NO", "isEnabled": "YES"},
                {"argument": "-ApplePersistenceIgnoreState YES", "isEnabled": "YES"})
            for item in arguments) and len({item.get("argument") for item in arguments}) == 2,
            "only the two reviewed host-test arguments are permitted")
        new_test.remove(arguments)
    require(xml_shape(old_test) == xml_shape(new_test), "test configuration or coverage changed")


def check_core_workflow(before, after):
    def workflow(value):
        text = value.decode("utf-8")
        require("\njobs:\n" in text, "workflow jobs section is missing")
        prefix, text = text.split("\njobs:\n", 1)
        headers = list(re.finditer(r"^  ([a-z][a-z0-9-]*):\n", text, re.MULTILINE))
        result = {}
        for index, header in enumerate(headers):
            name = header[1]
            require(name not in result, "duplicate workflow job")
            end = headers[index + 1].start() if index + 1 < len(headers) else len(text)
            result[name] = text[header.end():end]
        require({"build-cores", "build-mame", "build"} <= set(result), "missing core/host workflow job")
        return prefix, result

    old_prefix, old_jobs = workflow(before)
    new_prefix, new_jobs = workflow(after)
    require(old_prefix == new_prefix, "workflow prefix/global build environment changed")
    for name in ("build-cores", "build-mame"):
        def selection_only(block):
            # Only job selection may change; matrices, commands, build flags,
            # verification and upload steps must remain byte-identical.
            return re.sub(r"^    (?:if|needs): [^\n]*\n", "", block, flags=re.MULTILINE)
        require(selection_only(old_jobs[name]) == selection_only(new_jobs[name]),
                "core workflow build/settings/verification changed")

    def host_xcode_step(block):
        steps = list(re.finditer(r"^      - [^\n]*\n", block, re.MULTILINE))
        found = []
        for index, step in enumerate(steps):
            if step[0].strip() != "- name: Select Xcode":
                continue
            end = steps[index + 1].start() if index + 1 < len(steps) else len(block)
            found.append(block[step.start():end])
        require(len(found) == 1, "expected one explicit host Select Xcode step")
        return found[0]
    require(host_xcode_step(old_jobs["build"]) == host_xcode_step(new_jobs["build"]),
            "host Select Xcode toolchain changed")


def check_local(reference, snapshot):
    check_reference(reference)
    require(re.fullmatch(r"[0-9a-f]{40}", snapshot["current_source_sha"]), "current source SHA must be full")
    require(snapshot["source_sha"] == reference["source_sha"] and
            snapshot["source_parents"] == [reference["base_sha"], reference["head_sha"]],
            "source commit does not have the reviewed merge parents")
    require(snapshot["source_tree"] == snapshot["head_tree"] == reference["source_tree"],
            "source merge tree does not match the reviewed original head tree")
    changed = snapshot["changed_files"]
    require(isinstance(changed, list) and len(changed) == len(set(changed)), "invalid changed-file inventory")
    unsupported = sorted(set(changed) - ALLOWED_CHANGES)
    require(not unsupported, "unsupported source changes: " + ", ".join(unsupported))
    require(all(snapshot["current_modes"].get(path) == "100644" for path in changed),
            "allowed files must remain regular source files (no deletions/symlinks/mode changes)")
    require(isinstance(snapshot["source_info"], dict) and isinstance(snapshot["current_info"], dict),
            "host metadata must be a dictionary")
    for key in ("SUPublicEDKey", "OECoreUpdateCatalogs"):
        require(snapshot["source_info"].get(key) is not None and
                snapshot["source_info"].get(key) == snapshot["current_info"].get(key),
                f"host update trust/catalog contract changed: {key}")
    require(snapshot["source_catalog"] == snapshot["current_catalog"], "native catalog changed")
    check_scheme(snapshot["source_scheme"], snapshot["current_scheme"])
    check_core_workflow(snapshot["source_workflow"], snapshot["current_workflow"])


def check_remote(reference, run, jobs, artifacts):
    check_reference(reference)
    require(isinstance(run, dict) and isinstance(jobs, list) and isinstance(artifacts, list) and
            all(isinstance(item, dict) for item in jobs + artifacts), "invalid GitHub evidence structure")
    require(all(isinstance(item.get("name"), str) for item in jobs + artifacts),
            "invalid GitHub job/artifact name")
    require(run.get("id") == reference["run_id"] and run.get("status") == "completed",
            "source workflow run is missing or not completed")
    for key in ("repository", "head_repository"):
        repository = run.get(key, {})
        require(isinstance(repository, dict) and repository.get("id") == reference["repository_id"] and
                repository.get("full_name") == reference["repository"], "source run repository mismatch")
    require(run.get("event") == "pull_request" and run.get("path") == reference["workflow_path"] and
            run.get("head_sha") == reference["head_sha"], "source run head/event/workflow mismatch")
    require(positive_integer(run.get("run_attempt")), "source run attempt is missing")
    # Overall failure is allowed: the Intel HOST failed, not these core jobs.
    expected_jobs = {f"Build core ({core}, {arch})" for core in CORES for arch in ARCHITECTURES}
    core_jobs = [job for job in jobs if job.get("name", "").startswith("Build core (")]
    require(len(core_jobs) == 56 and {job.get("name") for job in core_jobs} == expected_jobs,
            "source run must have exactly all 56 expected core jobs, including both MAME CPUs")
    job_ids = set()
    for job in core_jobs:
        require(positive_integer(job.get("id")) and job["id"] not in job_ids,
                "missing or duplicate core job ID")
        job_ids.add(job["id"])
        require(job.get("run_id") == reference["run_id"] and job.get("head_sha") == reference["head_sha"] and
                positive_integer(job.get("run_attempt")) and job["run_attempt"] <= run["run_attempt"],
                "core job source/run/attempt mismatch")
        require(job.get("status") == "completed" and job.get("conclusion") == "success",
                f"core job did not succeed: {job['name']}")
    expected_artifacts = {f"reborn-core-{core}-{arch}" for core in CORES for arch in ARCHITECTURES}
    expected_artifacts.add("reborn-mame-source")
    selected = [item for item in artifacts if item.get("name", "").startswith("reborn-core-") or
                item.get("name") == "reborn-mame-source"]
    require(len(selected) == 57 and {item.get("name") for item in selected} == expected_artifacts,
            "exactly 56 core artifacts plus the separate MAME source artifact are required")
    artifact_ids = set()
    for artifact in selected:
        require(positive_integer(artifact.get("id")) and artifact["id"] not in artifact_ids,
                "missing or duplicate artifact ID")
        artifact_ids.add(artifact["id"])
        require(artifact.get("expired") is False and positive_integer(artifact.get("size_in_bytes")),
                f"artifact expired or empty: {artifact['name']}")
        require(isinstance(artifact.get("digest"), str) and
                re.fullmatch(r"sha256:[0-9a-f]{64}", artifact["digest"]), "missing GitHub artifact digest")
        source = artifact.get("workflow_run", {})
        require(isinstance(source, dict) and source.get("id") == reference["run_id"] and source.get("head_sha") == reference["head_sha"] and
                source.get("repository_id") == source.get("head_repository_id") == reference["repository_id"],
                "artifact belongs to a different run/source/repository")
    return {
        "source_run_attempt": run["run_attempt"], "source_run_conclusion": run.get("conclusion"),
        "core_jobs": [{key: job[key] for key in ("name", "id", "run_attempt")}
                      for job in sorted(core_jobs, key=lambda item: item["name"])],
        # These digests describe GitHub's artifact containers, NOT the inner
        # core ZIPs whose BUILD-INFO hashes must still be checked after download.
        "artifacts": [{"name": item["name"], "id": item["id"],
                       "github_artifact_digest": item["digest"], "size_in_bytes": item["size_in_bytes"]}
                      for item in sorted(selected, key=lambda item: item["name"])],
    }


def git(*arguments):
    return subprocess.check_output(["git", *arguments], cwd=ROOT, timeout=60)


def local_snapshot(current_sha):
    require(re.fullmatch(r"[0-9a-f]{40}", current_sha), "current source SHA must be a full commit ID")
    require(git("rev-parse", "HEAD").decode().strip() == current_sha, "current SHA does not match checked-out HEAD")
    require(not git("diff", "--name-only", "HEAD") and not git("ls-files", "--others", "--exclude-standard"),
            "tracked or untracked checkout changes are not reviewed CI source")
    source = REFERENCE["source_sha"]
    def blob(revision, path):
        return git("show", f"{revision}:{path}")
    changed = [path.decode("utf-8") for path in git("diff", "--name-only", "--no-renames", "-z", source, current_sha).split(b"\0") if path]
    modes = {}
    for path in changed:
        entry = git("ls-tree", current_sha, "--", path).split(b" ", 1)[0]
        modes[path] = entry.decode("ascii")
    return {
        "current_source_sha": current_sha, "source_sha": source,
        "source_parents": git("show", "-s", "--format=%P", source).decode().strip().split(),
        "source_tree": git("rev-parse", source + "^{tree}").decode().strip(),
        "head_tree": git("rev-parse", REFERENCE["head_sha"] + "^{tree}").decode().strip(),
        "changed_files": changed, "current_modes": modes,
        "source_info": plistlib.loads(blob(source, "OpenEmu/OpenEmu-Info.plist")),
        "current_info": plistlib.loads(blob(current_sha, "OpenEmu/OpenEmu-Info.plist")),
        "source_catalog": blob(source, "oecores.xml"), "current_catalog": blob(current_sha, "oecores.xml"),
        "source_scheme": blob(source, SCHEME), "current_scheme": blob(current_sha, SCHEME),
        "source_workflow": blob(source, REFERENCE["workflow_path"]),
        "current_workflow": blob(current_sha, REFERENCE["workflow_path"]),
    }


def github_json(path):
    try:
        data = subprocess.check_output(["gh", "api", "--hostname", "github.com", path],
                                       stderr=subprocess.PIPE, timeout=60)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise ValueError("GitHub metadata unavailable; check actions/contents read permissions and API connectivity") from error
    return json.loads(data)


def github_items(path, key):
    result, expected = [], None
    for page in range(1, 7):
        data = github_json(path + ("&" if "?" in path else "?") + f"per_page=100&page={page}")
        require(isinstance(data, dict), "invalid GitHub inventory response")
        count, items = data.get("total_count"), data.get(key)
        require(type(count) is int and 0 <= count <= 500 and isinstance(items, list), "invalid GitHub inventory response")
        require(expected in (None, count), "GitHub inventory changed while checking; retry later")
        expected = count
        result.extend(items)
        require(len(result) <= expected, "GitHub inventory has unexpected duplicate pages")
        if len(result) == expected:
            return result
        require(items, "GitHub inventory is incomplete")
    raise ValueError("GitHub inventory exceeded the bounded page limit")


def inspect(current_sha, config):
    result = {"schema": 1, "reuse": False, "current_source_sha": current_sha,
              "source_sha": REFERENCE["source_sha"], "source_run_id": REFERENCE["run_id"],
              "source_tree": REFERENCE["source_tree"], "source_head_sha": REFERENCE["head_sha"],
              "source_repository": REFERENCE["repository"],
              "source_run_url": f"https://github.com/{REFERENCE['repository']}/actions/runs/{REFERENCE['run_id']}",
              "source_tree_match": False, "changed_files": [], "archive_validation_required": True}
    try:
        reference = json.loads(config.read_text())
        check_reference(reference)
        snapshot = local_snapshot(current_sha)
        result["changed_files"] = snapshot["changed_files"]
        check_local(reference, snapshot)
        result["source_tree_match"] = True
        base = f"repos/{reference['repository']}/actions/runs/{reference['run_id']}"
        run = github_json(base)
        jobs = github_items(base + "/jobs?filter=latest", "jobs")
        artifacts = github_items(base + "/artifacts", "artifacts")
        result.update(check_remote(reference, run, jobs, artifacts))
        result.update(reuse=True, reason="unchanged core inputs; complete prior core CI evidence retained")
    except (ValueError, TypeError, KeyError, AttributeError, OSError, ET.ParseError, plistlib.InvalidFileException,
            subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        result["reason"] = str(error)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--current-source-sha", required=True)
    parser.add_argument("--config", type=Path, default=ROOT / ".github/core-artifact-reuse.json")
    args = parser.parse_args()
    print(json.dumps(inspect(args.current_source_sha, args.config), separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
