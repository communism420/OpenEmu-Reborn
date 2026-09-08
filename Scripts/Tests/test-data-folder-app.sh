#!/usr/bin/env bash
# Exercise an already built app in private data folders; never build/install it.
# Startup/storage checks only, not gameplay or UI rendering verification.
# Usage: ./Scripts/Tests/test-data-folder-app.sh /absolute/path/OpenEmu.app
set -euo pipefail

if [[ $# != 1 || "$1" == --help || "$1" == -h ]]; then
    echo "Usage: $0 /absolute/path/OpenEmu.app"
    [[ $# == 1 && ( "$1" == --help || "$1" == -h ) ]] && exit 0
    exit 2
fi

exec python3 - "$1" <<'PY'
import hashlib
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import uuid

# Every subprocess command is bounded. The three startup phases each get 30s;
# the global timer also covers commands, relaunches and the contention check.
# Cleanup may take at most STOP_TIMEOUT + KILL_TIMEOUT per owned app process.
COMMAND_TIMEOUT = 5
STARTUP_TIMEOUT = 30
CONTENTION_TIMEOUT = 10
STOP_TIMEOUT = 5
KILL_TIMEOUT = 2
TOTAL_TIMEOUT = 150
CANONICAL_LOCATOR_DOMAIN = "org.openemu.OpenEmu"
KNOWN_BUNDLE_IDS = {"org.openemu.OpenEmu", "org.openemu.OpenEmu.debug"}
LOCATOR_KEYS = ("OEDataFolderBookmark", "OEDataFolderIdentifier", "OEDataFolderPath")
OWNED_PROCESSES = []
OPEN_LOGS = []
WORKSPACE = None


class SmokeFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise SmokeFailure(message)


def run_command(arguments, timeout=COMMAND_TIMEOUT):
    return subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout, check=False)


def locator_snapshot(domains):
    result = {}
    for domain in domains:
        for key in LOCATOR_KEYS:
            value = run_command(["/usr/bin/defaults", "read", domain, key])
            require(value.returncode in (0, 1), "Could not read the real folder locator safely")
            # Compare both the canonical suite and the app's own Debug domain
            # when different. Never print or save bookmark contents or paths.
            result[(domain, key)] = (value.returncode, hashlib.sha256(value.stdout).digest())
    return result


def legacy_snapshot():
    # Read metadata only: do not traverse or hash potentially huge ROM libraries.
    root = Path.home() / "Library/Application Support/OpenEmu"
    result = {}
    if not root.exists() and not root.is_symlink():
        return result
    paths = [root]
    if root.is_dir() and not root.is_symlink():
        paths.extend(root.iterdir())
    for path in paths:
        metadata = path.lstat()
        result["." if path == root else path.name] = (metadata.st_dev, metadata.st_ino, metadata.st_mode,
                             metadata.st_size, metadata.st_mtime_ns, metadata.st_ctime_ns)
    return result


def read_plist(path):
    with path.open("rb") as stream:
        result = plistlib.load(stream)
    require(isinstance(result, dict), "Expected a property-list dictionary: " + str(path))
    return result


def normalized_path(value):
    # The app may spell /private/tmp as /tmp; compare filesystem paths, not text.
    return os.path.realpath(os.path.expanduser(value))


def marker_identifier(data_folder):
    marker = data_folder / ".openemu-data-folder.plist"
    require(marker.is_file() and not marker.is_symlink(), "Missing or linked data-folder marker")
    identity = read_plist(marker)
    require(identity.get("version") == 1, "Unexpected data-folder marker version")
    return str(uuid.UUID(identity["identifier"]))


def start_app(binary, data_folder, phase):
    log_path = WORKSPACE / (phase + ".log")
    log = log_path.open("wb")
    OPEN_LOGS.append(log)
    process = subprocess.Popen([
        str(binary), "--data-folder", str(data_folder),
        "-setupAssistantFinished", "YES",
        "-OEIntelSentryCrashReportingPrompted", "YES",
        "-OEIntelSentryCrashReportingEnabled", "NO",
        "-SUEnableAutomaticChecks", "NO",
    ], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
    OWNED_PROCESSES.append(process)
    print("Started {}: PID {}, log {}".format(phase, process.pid, log_path), flush=True)
    return process, log_path


def stop_app(process):
    # Popen.poll()/wait() track this child; no process-name or global kill is used.
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=STOP_TIMEOUT)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=KILL_TIMEOUT)
            raise SmokeFailure("Owned app PID {} required SIGKILL after SIGTERM".format(process.pid))
    else:
        process.wait(timeout=KILL_TIMEOUT)


def database_is_open(process, database, timeout):
    result = run_command(["/usr/sbin/lsof", "-n", "-P", "-a", "-p", str(process.pid),
                          "-Fn", str(database)], timeout=timeout)
    require(result.returncode in (0, 1), "lsof could not check the owned app's database")
    expected = normalized_path(str(database))
    return any(line.startswith("n") and normalized_path(line[1:]) == expected
               for line in result.stdout.decode("utf-8", errors="replace").splitlines())


def wait_ready(process, data_folder, phase, old_inventory_stamp=None, expected_id=None):
    deadline = time.monotonic() + STARTUP_TIMEOUT
    settings_path = data_folder / "Settings.plist"
    database = data_folder / "Game Library/Library.storedata"
    inventory = data_folder / "Logs/core-inventory.txt"
    last_condition = "settings, database and inventory have not all appeared"
    while time.monotonic() < deadline:
        require(process.poll() is None, "{} exited before becoming ready; see its log".format(phase))
        if settings_path.is_file() and database.is_file() and inventory.is_file():
            try:
                settings = read_plist(settings_path)
                identity = marker_identifier(data_folder)
                last_root = settings.get("OEDataFolderLastPath", "")
                database_path = settings.get("databasePath", "")
                last_condition = "settings do not point to this data folder/library"
                paths_match = (
                    isinstance(last_root, str) and isinstance(database_path, str)
                    and normalized_path(last_root) == normalized_path(str(data_folder))
                    and normalized_path(database_path) == normalized_path(str(database.parent))
                )
                inventory_is_new = old_inventory_stamp is None or inventory.stat().st_mtime_ns != old_inventory_stamp
                if paths_match and inventory_is_new:
                    require(expected_id is None or identity == expected_id, "The folder UUID changed during " + phase)
                    last_condition = "the owned app has not opened this database (lsof)"
                    remaining = deadline - time.monotonic()
                    if remaining > 0 and database_is_open(process, database, min(COMMAND_TIMEOUT, remaining)):
                        require(process.poll() is None, "{} exited during readiness checks".format(phase))
                        print("PASS: {} created/refreshed files and opened the selected database".format(phase), flush=True)
                        return identity
            except (FileNotFoundError, plistlib.InvalidFileException):
                last_condition = "a startup file is still being replaced"
        time.sleep(0.2)
    raise SmokeFailure("{} did not become ready in {}s: {}. A first-run/permission modal may need diagnosis; see the retained log.".format(
        phase, STARTUP_TIMEOUT, last_condition))


def interrupt(signum, _frame):
    raise SmokeFailure("Interrupted by signal {} (global timeout is {}s)".format(signum, TOTAL_TIMEOUT))


def main():
    global WORKSPACE
    app = Path(sys.argv[1])
    require(app.is_absolute(), "APP_PATH must be absolute")
    app = app.resolve(strict=True)
    require(app.is_dir() and app.suffix == ".app", "APP_PATH must be an existing .app bundle")
    info = read_plist(app / "Contents/Info.plist")
    bundle_id = info.get("CFBundleIdentifier")
    require(bundle_id in KNOWN_BUNDLE_IDS
            and info.get("CFBundleExecutable") == "OpenEmu", "The bundle is not the expected OpenEmu application")
    binary = app / "Contents/MacOS/OpenEmu"
    require(binary.is_file() and os.access(binary, os.X_OK), "OpenEmu executable is missing or not executable")
    existing = run_command(["/usr/bin/pgrep", "-x", "OpenEmu"])
    require(existing.returncode == 1, "OpenEmu is already running (or pgrep failed); quit it before this test")

    locator_domains = [CANONICAL_LOCATOR_DOMAIN]
    if bundle_id != CANONICAL_LOCATOR_DOMAIN:
        locator_domains.append(bundle_id)
    before_locator = locator_snapshot(locator_domains)
    before_legacy = legacy_snapshot()
    WORKSPACE = Path(tempfile.mkdtemp(prefix="openemu-data-folder-app-", dir="/private/tmp")).resolve()
    data_folder = WORKSPACE / "Data"
    data_folder.mkdir()
    print("Retained smoke workspace: {}".format(WORKSPACE), flush=True)
    print("Timeouts: startup {}s/phase, contention {}s, command {}s, total {}s".format(
        STARTUP_TIMEOUT, CONTENTION_TIMEOUT, COMMAND_TIMEOUT, TOTAL_TIMEOUT), flush=True)
    result = False
    try:
        first, _ = start_app(binary, data_folder, "first-launch")
        identity = wait_ready(first, data_folder, "first-launch")
        stop_app(first)
        require(marker_identifier(data_folder) == identity, "SIGTERM changed the folder UUID")

        inventory_stamp = (data_folder / "Logs/core-inventory.txt").stat().st_mtime_ns
        reopened, _ = start_app(binary, data_folder, "relaunch")
        wait_ready(reopened, data_folder, "relaunch", inventory_stamp, identity)
        stop_app(reopened)

        moved_folder = WORKSPACE / "MovedData"
        require(not moved_folder.exists(), "Refusing to replace a move destination")
        data_folder.rename(moved_folder)  # Only this run's stopped, private fixture.
        inventory_stamp = (moved_folder / "Logs/core-inventory.txt").stat().st_mtime_ns
        moved, _ = start_app(binary, moved_folder, "moved-folder")
        wait_ready(moved, moved_folder, "moved-folder", inventory_stamp, identity)
        require(not data_folder.exists(), "The app recreated the old data path after the move")
        print("PASS: folder UUID survived relaunch/move; root and database paths rebased", flush=True)

        contender, contender_log = start_app(binary, moved_folder, "second-writer")
        try:
            status = contender.wait(timeout=CONTENTION_TIMEOUT)
        except subprocess.TimeoutExpired:
            raise SmokeFailure("Second writer hung instead of rejecting the locked data folder")
        require(status > 0, "Second writer must exit with an error, not succeed or die from a signal")
        message = contender_log.read_text(encoding="utf-8", errors="replace")
        require("Another OpenEmu application is using this data folder" in message,
                "Second writer did not report the expected settings-lock error; see its log")
        require(moved.poll() is None, "The first writer exited during the contention test")
        require(marker_identifier(moved_folder) == identity, "Contention changed the folder UUID")
        stop_app(moved)
        print("PASS: concurrent writer rejected with the expected lock error", flush=True)
        result = True
    finally:
        for process in reversed(OWNED_PROCESSES):
            try:
                stop_app(process)
            except (SmokeFailure, OSError, subprocess.TimeoutExpired) as error:
                print("FAIL: cleanup: {}".format(error), file=sys.stderr, flush=True)
                result = False
        require(locator_snapshot(locator_domains) == before_locator,
                "Folder locator keys changed in the canonical or active app domain; no automatic restoration was attempted")
        require(legacy_snapshot() == before_legacy, "Legacy OpenEmu folder metadata changed; inspect it before continuing")
    require(result, "One or more cleanup checks failed")
    print("PASS: canonical/app-domain locator keys and legacy top-level metadata unchanged", flush=True)
    print("PASS: app storage smoke only; gameplay and UI rendering were not tested", flush=True)
    print("Logs and test data remain at: {}".format(WORKSPACE), flush=True)


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGALRM):
    signal.signal(sig, interrupt)
signal.alarm(TOTAL_TIMEOUT)
exit_code = 0
try:
    main()
except (SmokeFailure, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
    exit_code = 1
    print("FAIL: {}".format(error), file=sys.stderr, flush=True)
finally:
    signal.alarm(0)
    # Also covers an interrupt while the main cleanup itself was in progress.
    for process in reversed(OWNED_PROCESSES):
        try:
            stop_app(process)
        except (SmokeFailure, OSError, subprocess.TimeoutExpired) as error:
            exit_code = 1
            print("FAIL: final cleanup: {}".format(error), file=sys.stderr, flush=True)
    for log in OPEN_LOGS:
        log.close()
    if WORKSPACE is not None:
        print("Inspection directory (not deleted): {}".format(WORKSPACE), flush=True)
sys.exit(exit_code)
PY
