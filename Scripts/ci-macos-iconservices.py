#!/usr/bin/env python3
"""Narrow, reversible workaround for one broken GitHub-hosted Intel VM image.

This is not an OpenEmu fix or a replacement for native panel tests. The affected
image's iconservicesagent aborts in Metal/RenderBox, blocking AppKit icon clients:
https://github.com/actions/runner-images/issues/14751
https://github.com/actions/runner-images/issues/14773

Only the exact hosted image AND a matching structured crash report permit any
change. Generic icons are acceptable for panel geometry tests; icon rendering is
not being tested. Always run `cleanup` in an `if: always()` workflow step.
Nothing here changes TCC, trust, signatures, caches, or application preferences.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import pwd
import re
import stat
import subprocess
import sys
import tempfile


IMAGE_VERSION = "20260824.0517.1"
OS_BUILD = "25G76"
SERVICE = "com.apple.iconservices.iconservicesagent"
SERVICE_PLIST = f"/System/Library/LaunchAgents/{SERVICE}.plist"
STATE_NAME = "openemu-ci-iconservices-state.json"
COMMAND_TIMEOUT = 5
MAX_REPORT_BYTES = 2 * 1024 * 1024
REPORT_NAME = re.compile(r"iconservicesagent(?:-\d{4}-\d{2}-\d{2}-\d{6})?\.ips\Z")
METAL_SYMBOL = "+[MTLLoader sliceIDForDevice:legacyDriverVersion:airntDriverVersion:]"


def note(message):
    print(f"IconServices CI guard: {message}", flush=True)


def command(arguments):
    """Every external command, including diagnostics and recovery, is bounded."""
    try:
        result = subprocess.run(arguments, capture_output=True, text=True,
                                timeout=COMMAND_TIMEOUT, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"{Path(arguments[0]).name} {arguments[1]} failed or timed out") from error
    if result.returncode:
        raise RuntimeError(f"{Path(arguments[0]).name} {arguments[1]} exited {result.returncode}")
    return result.stdout


def guarded_context():
    """Use real machine/OS/UID values, not the matrix's claimed architecture."""
    required = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                "RUNNER_OS": "macOS", "ImageVersion": IMAGE_VERSION}
    if any(os.environ.get(key) != value for key, value in required.items()):
        return None
    if platform.system() != "Darwin" or platform.machine() != "x86_64" or os.getuid() == 0:
        return None
    if command(["/usr/bin/sw_vers", "-buildVersion"]).strip() != OS_BUILD:
        return None
    uid = os.getuid()
    run_id, attempt, job = (os.environ.get(key, "") for key in
                            ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB"))
    if not run_id.isdecimal() or not attempt.isdecimal() or not re.fullmatch(r"[A-Za-z0-9_-]+", job):
        raise RuntimeError("missing exact GitHub run/attempt/job identity")
    return {"schema": 1, "image": IMAGE_VERSION, "os_build": OS_BUILD, "uid": uid,
            "service": f"gui/{uid}/{SERVICE}", "run_id": run_id, "attempt": attempt, "job": job}


def matching_report(contents, uid):
    """Require Metal and RenderBox on the actual faulting thread, not free text."""
    try:
        decoder = json.JSONDecoder()
        metadata, offset = decoder.raw_decode(contents.lstrip())
        report, end = decoder.raw_decode(contents.lstrip()[offset:].lstrip())
        if contents.lstrip()[offset:].lstrip()[end:].strip():
            return False
        if not isinstance(metadata, dict) or not isinstance(report, dict):
            return False
        if (metadata.get("app_name") != "iconservicesagent" or
                metadata.get("os_version") != f"macOS 26.6.1 ({OS_BUILD})" or
                report.get("procName") != "iconservicesagent" or
                report.get("procPath") != "/System/Library/CoreServices/iconservicesagent" or
                report.get("userID") != uid or report.get("cpuType") != "X86-64" or
                report.get("osVersion", {}).get("build") != OS_BUILD or
                report.get("exception", {}).get("type") != "EXC_CRASH" or
                report.get("exception", {}).get("signal") != "SIGABRT"):
            return False
        index = report["faultingThread"]
        if type(index) is not int or index < 0:
            return False
        frames = report["threads"][index]["frames"]
        images = report["usedImages"]
        metal = renderbox = False
        for frame in frames:
            image_index = frame.get("imageIndex")
            if type(image_index) is not int or not 0 <= image_index < len(images):
                continue
            image = images[image_index]
            if (image.get("path") == "/System/Library/Frameworks/Metal.framework/Versions/A/Metal" and
                    frame.get("symbol") == METAL_SYMBOL):
                metal = True
            if (image.get("path") == "/System/Library/PrivateFrameworks/RenderBox.framework/Versions/A/RenderBox" and
                    str(frame.get("symbol", "")).startswith("RB::")):
                renderbox = True
        return metal and renderbox
    except (ValueError, KeyError, TypeError, AttributeError, IndexError):
        return False


def read_regular(path, maximum, *, private=False):
    """Do not follow a report/state symlink or read an unbounded file."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise ValueError("not a bounded regular file")
        if private and (info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077):
            raise ValueError("state file is not private and owned by this user")
        content = stream.read(maximum + 1)
        if len(content) > maximum:
            raise ValueError("file grew past the size limit")
        return content.decode("utf-8")


def find_evidence(uid):
    # Do not use HOME/CFFIXED_USER_HOME: panel tests deliberately isolate those.
    directory = Path(pwd.getpwuid(uid).pw_dir) / "Library/Logs/DiagnosticReports"
    if not directory.is_dir() or directory.resolve() != directory:
        return None
    reports = sorted((path for path in directory.iterdir() if REPORT_NAME.fullmatch(path.name)), reverse=True)
    for path in reports[:64]:
        try:
            if matching_report(read_regular(path, MAX_REPORT_BYTES), uid):
                return path.name
        except (OSError, ValueError):
            continue
    return None


def state_path():
    raw = os.environ.get("RUNNER_TEMP", "")
    directory = Path(raw)
    actual_home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    if (not raw or not directory.is_absolute() or directory in (Path("/"), actual_home) or
            directory.resolve() != directory or not directory.is_dir()):
        raise RuntimeError("RUNNER_TEMP must be an existing, non-symlinked dedicated directory")
    info = directory.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise RuntimeError("RUNNER_TEMP must be owned by this user and not writable by others")
    return directory / STATE_NAME


def write_state(path, state, *, create=False):
    # Never replace someone else's file or follow a symlink. This job is serial.
    if create:
        descriptor = os.open(path, os.O_WRONLY | os.O_NOFOLLOW | os.O_CREAT | os.O_EXCL, 0o600)
        temporary = None
    else:
        read_regular(path, 4096, private=True)
        descriptor, temporary = tempfile.mkstemp(prefix=STATE_NAME + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(json.dumps(state, sort_keys=True) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        if temporary:
            os.replace(temporary, path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def load_state(path, context):
    state = json.loads(read_regular(path, 4096, private=True))
    expected_keys = set(context) | {"restore_enabled", "bootout_attempted"}
    if (not isinstance(state, dict) or set(state) != expected_keys or
            any(state.get(key) != value or type(state.get(key)) is not type(value)
                for key, value in context.items()) or state["restore_enabled"] is not True or
            type(state["bootout_attempted"]) is not bool):
        raise RuntimeError("state does not belong to this exact runner job and service")
    return state


def previously_disabled(context):
    output = command(["/bin/launchctl", "print-disabled", f"gui/{context['uid']}"])
    if not re.fullmatch(r"\s*disabled services = \{.*\}\s*", output, re.DOTALL):
        raise RuntimeError("cannot establish the original service enabled state")
    entries = re.findall(r'"' + re.escape(SERVICE) + r'"\s*=>\s*(true|false)', output)
    if len(entries) > 1 or output.count(SERVICE) != len(entries):
        raise RuntimeError("ambiguous original service enabled state")
    return entries == ["true"]


def restore(context, path, state):
    command(["/bin/launchctl", "enable", context["service"]])
    if state["bootout_attempted"]:
        try:
            command(["/bin/launchctl", "bootstrap", f"gui/{context['uid']}", SERVICE_PLIST])
        except RuntimeError:
            # A failed/interrupted bootout may have left the job loaded. Only a
            # successful exact-service query proves that bootstrap is unnecessary.
            command(["/bin/launchctl", "print", context["service"]])
    path.unlink()
    note("restored the original enabled service; removed only this job's recovery marker")


def apply(context):
    path = state_path()
    if path.exists() or path.is_symlink():
        raise RuntimeError("a recovery marker already exists; run cleanup first")
    evidence = find_evidence(context["uid"])
    if evidence is None:
        note("no matching Metal/RenderBox crash evidence; no workaround applied; native tests must still run")
        return
    note(f"matched {evidence}: iconservicesagent SIGABRT, {OS_BUILD}, Metal slice assertion + RenderBox")
    if previously_disabled(context):
        note("service was already disabled; left unchanged; native tests must still run")
        return
    state = {**context, "restore_enabled": True, "bootout_attempted": False}
    write_state(path, state, create=True)
    try:
        command(["/bin/launchctl", "disable", context["service"]])
        state["bootout_attempted"] = True
        write_state(path, state)
        command(["/bin/launchctl", "bootout", context["service"]])
    except (RuntimeError, OSError) as error:
        try:
            restore(context, path, state)
        except (RuntimeError, OSError) as recovery_error:
            raise RuntimeError(f"workaround failed; restoration also failed ({recovery_error}); retain marker for cleanup") from error
        raise RuntimeError("workaround failed; original enabled state restored") from error
    note("temporary generic-icon fallback active on the affected VM only; native panel assertions remain required")


def cleanup(context):
    path = state_path()
    if not path.exists() and not path.is_symlink():
        note("no recovery marker; nothing to restore")
        return
    restore(context, path, load_state(path, context))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("apply", "cleanup"))
    arguments = parser.parse_args(argv)
    try:
        context = guarded_context()
        if context is None:
            note("not the exact affected GitHub-hosted Intel image; no action")
            return 0
        {"apply": apply, "cleanup": cleanup}[arguments.action](context)
        return 0
    except (RuntimeError, OSError, ValueError) as error:
        print(f"IconServices CI guard ERROR: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
