#!/usr/bin/env bash
# Exercise an already built app's actual reset action and worker using private
# fixtures. The injected test-only library never uses the real macOS Trash.
set -euo pipefail
if [[ $# != 1 || "$1" == --help || "$1" == -h ]]; then
    echo "Usage: bash $0 /absolute/path/OpenEmu.app"
    [[ $# == 1 && ( "$1" == --help || "$1" == -h ) ]] && exit 0
    exit 2
fi
reset_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$1" "$reset_tests_directory/DataRemovalAppDriver.m" <<'PY'
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

owned = []
logs = []

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def run(arguments, timeout=10):
    return subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)

def locator_snapshot():
    result = {}
    for domain in ('org.openemu.OpenEmu', 'org.openemu.OpenEmu.debug'):
        for key in ('OEDataFolderBookmark', 'OEDataFolderIdentifier', 'OEDataFolderPath'):
            value = run(['/usr/bin/defaults', 'read', domain, key])
            require(value.returncode in (0, 1), 'Cannot safely inspect real folder locator')
            result[(domain, key)] = (value.returncode, hashlib.sha256(value.stdout).digest())
    return result

def read_plist(path):
    with path.open('rb') as stream:
        return plistlib.load(stream)

def write_plist(path, value):
    with path.open('wb') as stream:
        plistlib.dump(value, stream)

def stop_owned(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)

def main():
    app = Path(sys.argv[1])
    require(app.is_absolute(), 'Application path must be absolute')
    app = app.resolve(strict=True)
    info = read_plist(app / 'Contents/Info.plist')
    require(info.get('CFBundleIdentifier') in ('org.openemu.OpenEmu', 'org.openemu.OpenEmu.debug')
            and info.get('CFBundleExecutable') == 'OpenEmu', 'Unexpected application bundle')
    running = run(['/usr/bin/pgrep', '-x', 'OpenEmu'])
    require(running.returncode in (0, 1), 'Process inspection unavailable; run this UI regression with normal macOS process access')
    require(running.returncode == 1, 'OpenEmu is already running; this test will not close it')
    before = locator_snapshot()
    work = Path(tempfile.mkdtemp(prefix='openemu-reset-action-', dir='/private/tmp')).resolve()
    print('Retained private regression workspace:', work, flush=True)
    library = work / 'DataRemovalAppDriver.dylib'
    compile_result = run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-fmodules',
                          '-fmodules-cache-path=' + str(work / 'ModuleCache'),
                          '-Wall', '-Wextra', '-Werror', sys.argv[2], '-framework', 'Foundation',
                          '-framework', 'AppKit', '-framework', 'IOKit', '-framework', 'CoreGraphics',
                          '-o', str(library)], timeout=60)
    require(compile_result.returncode == 0, compile_result.stderr.decode(errors='replace'))
    signed = run(['/usr/bin/codesign', '--force', '--sign', '-', str(library)])
    require(signed.returncode == 0, 'Could not ad-hoc sign private test driver')
    (work / 'Fixture Trash').mkdir()
    (work / 'Private Home').mkdir()
    events = work / 'driver-events.txt'

    def fixture(name):
        data = work / name
        data.mkdir()
        identity = str(uuid.uuid4()).upper()
        write_plist(data / '.openemu-data-folder.plist', {'version': 1, 'identifier': identity})
        write_plist(data / 'Settings.plist', {'setupAssistantFinished': True, 'OEResetRegressionSentinel': identity})
        (data / 'Bindings').mkdir()
        write_plist(data / 'Bindings/RegressionUnloaded.oebindings', {'RegressionSentinel': identity})
        (data / '.oe_credentials').write_bytes(b'synthetic-credential-sentinel-no-keychain-migration')
        (data / 'Game Library').mkdir()
        (data / 'Game Library/retained-game-sentinel.bin').write_bytes(b'private-game-must-survive')
        return data, identity

    def launch(data, identity, mode):
        log = (work / (mode + '.log')).open('wb')
        logs.append(log)
        env = os.environ.copy()
        env.update({'DYLD_INSERT_LIBRARIES': str(library), 'OE_DISABLE_UPDATE_CHECK': 'YES',
                    'CFFIXED_USER_HOME': str(work / 'Private Home'),
                    'OE_RESET_TEST_WORKSPACE': str(work), 'OE_RESET_TEST_DATA_ROOT': str(data),
                    'OE_RESET_TEST_MARKER': identity, 'OE_RESET_TEST_MODE': mode})
        args = [str(app / 'Contents/MacOS/OpenEmu'), '--data-folder', str(data),
                '-OEIntelSentryCrashReportingPrompted', 'YES', '-OEIntelSentryCrashReportingEnabled', 'NO',
                # Empty disc-system onboarding is unrelated to reset and can
                # attach a delayed sheet that prevents AppKit from quitting.
                '-OESkipDiscGuideMessageKey', 'YES',
                '-SUEnableAutomaticChecks', 'NO']
        process = subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        owned.append(process)
        print('Started private', mode, 'PID', process.pid, flush=True)
        if mode in ('cancel', 'cancel-close'):
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                text = events.read_text() if events.exists() else ''
                require('FAIL ' not in text, 'Test driver reported failure; see ' + str(events))
                require(process.poll() is None, 'Cancellation must leave the test app alive')
                if mode + ' CANCELLED_APP_STILL_RUNNING' in text:
                    return text
                time.sleep(0.1)
            raise RuntimeError('Cancellation did not return to the app within 45 seconds')
        status = process.wait(timeout=55)
        require(status == 0, '{} exited with {} (negative means signal/crash); see {}'.format(mode, status, log.name))
        text = events.read_text()
        require('FAIL ' not in text, 'Test driver reported failure; see ' + str(events))
        return text

    try:
        cancellation_modes = () if os.environ.get('OE_RESET_TEST_CONFIRM_ONLY') == 'YES' else ('cancel', 'cancel-close', 'cancel-quit')
        for mode in cancellation_modes:
            data, identity = fixture(mode + '-Data')
            credentials = (data / '.oe_credentials').read_bytes()
            bindings = (data / 'Bindings/RegressionUnloaded.oebindings').read_bytes()
            event_text = launch(data, identity, mode)
            require(mode + ' CANCELLED_APP_STILL_RUNNING' in event_text, mode + ' did not return to the app')
            require(mode + ' CHOOSER_CONTINUE' in event_text, mode + ' did not exercise the real chooser')
            if mode == 'cancel':
                require('cancel CONFIRMATION_CANCELLED' in event_text, 'Confirmation cancel button was not exercised')
            if mode == 'cancel-close':
                require('cancel-close DOCUMENT_CLOSE_CANCELLED' in event_text, 'Document close cancellation was not exercised')
            if mode == 'cancel-quit':
                require('cancel-quit DEFERRED_QUIT_CANCELLED' in event_text and 'cancel-quit ORDINARY_QUIT_AFTER_CANCEL' in event_text,
                        'Asynchronous quit cancellation and later ordinary quit were not exercised')
            require(read_plist(data / 'Settings.plist').get('OEResetRegressionSentinel') == identity,
                    'Cancellation changed stored settings')
            require((data / 'Settings.plist.lock').is_file(), 'Cancellation removed the settings writer lock')
            require((data / '.oe_credentials').read_bytes() == credentials, 'Cancellation changed credentials')
            require((data / 'Bindings/RegressionUnloaded.oebindings').read_bytes() == bindings, 'Cancellation changed bindings')
            require(not list(data.glob('.openemu-removal-*.json')), 'Cancellation left a pending worker request')
            require(not list((work / 'Fixture Trash').iterdir()), 'Cancellation moved data to fixture Trash')
            stop_owned(owned[-1])
            print('PASS:', mode, 'preserved settings, bindings, accounts and library', flush=True)

        data, identity = fixture('confirmed-Data')
        confirmation_events = launch(data, identity, 'confirm')
        for expected in ('GAME_DOCUMENT_CONTROLLER_VERIFIED', 'CHOOSER_CONTINUE', 'RESET_CONFIRMED',
                         'DEFERRED_QUIT_REQUESTED', 'DEFERRED_QUIT_ACCEPTED', 'APPLICATION_WILL_TERMINATE'):
            require('confirm ' + expected in confirmation_events, 'Confirmation did not exercise ' + expected)
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if not (data / 'Settings.plist').exists() and not (data / 'Settings.plist.lock').exists() and not (data / 'Bindings').exists():
                break
            time.sleep(0.1)
        require(not (data / 'Settings.plist').exists(), 'Worker recreated Settings.plist after reset')
        require(not (data / 'Settings.plist.lock').exists(), 'Worker left Settings.plist.lock after completed reset')
        require(not (data / 'Bindings').exists(), 'Worker did not remove selected controller mappings')
        require(len((data / '.oe_credentials').read_bytes()) >= 28, 'Empty encrypted credential replacement missing')
        require((data / '.oe_credentials').read_bytes() != b'synthetic-credential-sentinel-no-keychain-migration', 'Credentials were not reset')
        require((data / 'Game Library/retained-game-sentinel.bin').read_bytes() == b'private-game-must-survive', 'Unselected library file changed')
        require(read_plist(data / '.openemu-data-folder.plist')['identifier'] == identity, 'Data-folder identity changed')
        require(not list(data.glob('.openemu-removal-*.json')), 'Worker left request file behind')
        trashed = list((work / 'Fixture Trash').iterdir())
        require(len(trashed) == 1, 'Expected one private recoverable trash folder')
        require(read_plist(trashed[0] / 'Settings.plist').get('OEResetRegressionSentinel') == identity, 'Original settings missing from recovery folder')
        require((trashed[0] / 'Bindings/RegressionUnloaded.oebindings').is_file(), 'Original bindings missing from recovery folder')
        require((trashed[0] / '.oe_credentials').is_file(), 'Original credentials missing from recovery folder')
        print('PASS: actual confirmation -> document callback -> normal exit -> worker reset; settings and lock absent, game retained', flush=True)
        event_text = launch(data, identity, 'relaunch')
        require('relaunch FIRST_RUN_ASSISTANT_VISIBLE' in event_text, 'First-run assistant not detected after reset')
        require((data / 'Settings.plist').is_file() and (data / 'Settings.plist.lock').is_file(),
                'A new launch did not create its own normal settings and writer lock')
        require('OEResetRegressionSentinel' not in read_plist(data / 'Settings.plist'),
                'New launch resurrected the removed settings')
        print('PASS: relaunch presents the actual first-run assistant and creates fresh settings and lock', flush=True)
    finally:
        for process in owned:
            stop_owned(process)
        require(locator_snapshot() == before, 'Real folder locator changed; no automatic restoration attempted')
    print('PASS: real folder locators unchanged; no real Trash, user libraries or core builds used', flush=True)

try:
    main()
except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
    print('FAIL:', error, file=sys.stderr, flush=True)
    sys.exit(1)
finally:
    for process in owned:
        stop_owned(process)
    for log in logs:
        log.close()
PY
