#!/usr/bin/env bash
# Existing app only: test real game-document dispatch with absent synthetic ROMs.
# No emulation, core compilation, user library, real settings or Trash operations.
set -euo pipefail
if [[ $# != 1 || "$1" == --help || "$1" == -h ]]; then
    echo "Usage: bash $0 /absolute/path/OpenEmu.app"
    [[ $# == 1 && ( "$1" == --help || "$1" == -h ) ]] && exit 0
    exit 2
fi
game_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$1" "$game_tests_directory/GameDocumentAppDriver.m" <<'PY'
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import uuid

process = None
log = None

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def run(arguments, timeout=10):
    return subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)

def locators():
    result = {}
    for domain in ('org.openemu.OpenEmu', 'org.openemu.OpenEmu.debug'):
        for key in ('OEDataFolderBookmark', 'OEDataFolderIdentifier', 'OEDataFolderPath'):
            value = run(['/usr/bin/defaults', 'read', domain, key])
            require(value.returncode in (0, 1), 'Cannot safely inspect real folder locators')
            result[(domain, key)] = (value.returncode, hashlib.sha256(value.stdout).digest())
    return result

def write_plist(path, value):
    with path.open('wb') as stream:
        plistlib.dump(value, stream)

def stop():
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)

def main():
    global process, log
    app = Path(sys.argv[1])
    require(app.is_absolute(), 'Application path must be absolute')
    app = app.resolve(strict=True)
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    require(info.get('CFBundleIdentifier') in ('org.openemu.OpenEmu', 'org.openemu.OpenEmu.debug')
            and info.get('CFBundleExecutable') == 'OpenEmu', 'Unexpected application bundle')
    running = run(['/usr/bin/pgrep', '-x', 'OpenEmu'])
    require(running.returncode in (0, 1), 'Process inspection unavailable; normal macOS process access is required')
    require(running.returncode == 1, 'OpenEmu is already running; this test will not close it')
    original_locators = locators()
    work = Path(tempfile.mkdtemp(prefix='openemu-game-dispatch-', dir='/private/tmp')).resolve()
    print('Retained private game-dispatch workspace:', work, flush=True)
    library = work / 'GameDocumentAppDriver.dylib'
    compilation = run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-fmodules',
                       '-fmodules-cache-path=' + str(work / 'ModuleCache'), '-Wall', '-Wextra', '-Werror',
                       sys.argv[2], '-framework', 'Foundation', '-framework', 'AppKit', '-framework', 'CoreData',
                       '-o', str(library)], timeout=60)
    require(compilation.returncode == 0, compilation.stderr.decode(errors='replace'))
    require(run(['/usr/bin/codesign', '--force', '--sign', '-', str(library)]).returncode == 0, 'Cannot sign private test driver')
    data = work / 'Data'
    data.mkdir()
    identity = str(uuid.uuid4()).upper()
    write_plist(data / '.openemu-data-folder.plist', {'version': 1, 'identifier': identity})
    write_plist(data / 'Settings.plist', {'setupAssistantFinished': True, 'OEGameDispatchSentinel': identity})
    credentials = b'synthetic-test-credential-sentinel-prevents-keychain-migration'
    (data / '.oe_credentials').write_bytes(credentials)
    (work / 'Private Home').mkdir()
    env = os.environ.copy()
    env.update({'DYLD_INSERT_LIBRARIES': str(library), 'OE_DISABLE_UPDATE_CHECK': 'YES',
                'CFFIXED_USER_HOME': str(work / 'Private Home'), 'OE_GAME_TEST_WORKSPACE': str(work),
                'OE_GAME_TEST_DATA_ROOT': str(data)})
    log = (work / 'game-dispatch.log').open('wb')
    try:
        process = subprocess.Popen([str(app / 'Contents/MacOS/OpenEmu'), '--data-folder', str(data),
            '-OEIntelSentryCrashReportingPrompted', 'YES', '-OEIntelSentryCrashReportingEnabled', 'NO',
            '-SUEnableAutomaticChecks', 'NO'], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 40
        events = work / 'game-driver-events.txt'
        while time.monotonic() < deadline:
            text = events.read_text() if events.exists() else ''
            require('FAIL ' not in text, 'Injected regression failed; see ' + str(events))
            require(process.poll() is None, 'App exited/crashed before dispatch verification; see ' + str(log.name))
            if 'GAME_DISPATCH_REGRESSION_PASS_APP_ALIVE' in text:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('Game-dispatch regression timed out; see ' + str(log.name))
        for expected in ('FIRST_DOCUMENT_CONTROLLER_GAME_VERIFIED', 'GAME_DOCUMENT_CONTROLLER_VERIFIED', 'MISSING_NES_GAME_ERROR_CALLBACK',
                         'MISSING_NDS_GAME_ERROR_CALLBACK', 'MISSING_NES_ROM_ERROR_CALLBACK'):
            require(expected in text, 'Missing real dispatch result: ' + expected)
        require((data / '.oe_credentials').read_bytes() == credentials, 'Unrelated fixture credentials changed')
        require(not (data / 'missing-regression.nes').exists() and not (data / 'missing-regression.nds').exists(),
                'Missing-ROM test must not create or download ROMs')
        print('PASS: shared GameDocumentController dispatches actual NES/NDS game and ROM opens to normal missing-file errors', flush=True)
        print('PASS: app remains alive; no emulator core was launched or rebuilt', flush=True)
    finally:
        stop()
        require(locators() == original_locators, 'Real data-folder locator changed; no automatic restoration attempted')
    print('PASS: real folder locators unchanged; all test files remain only in', work, flush=True)

try:
    main()
except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
    print('FAIL:', error, file=sys.stderr, flush=True)
    sys.exit(1)
finally:
    stop()
    if log:
        log.close()
PY
