#!/usr/bin/env bash
# Exercise an already-built app's actual permission sheet using simulated
# denied/granted states, never actual macOS authorization. No builds of cores.
set -euo pipefail
if [[ $# != 1 || "$1" == --help || "$1" == -h ]]; then
    echo "Usage: bash $0 /absolute/path/OpenEmu.app"
    [[ $# == 1 && ( "$1" == --help || "$1" == -h ) ]] && exit 0
    exit 2
fi
permission_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$1" "$permission_tests_directory/InputMonitoringAppDriver.m" <<'PY'
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import uuid

owned = []

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

def fingerprint(app):
    return {path: hashlib.sha256((app / path).read_bytes()).digest() for path in
            ('Contents/MacOS/OpenEmu', 'Contents/Info.plist', 'Contents/_CodeSignature/CodeResources')}

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
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    require(info.get('CFBundleIdentifier') in ('org.openemu.OpenEmu', 'org.openemu.OpenEmu.debug')
            and info.get('CFBundleExecutable') == 'OpenEmu', 'Unexpected application bundle')
    running = run(['/usr/bin/pgrep', '-x', 'OpenEmu'])
    require(running.returncode in (0, 1), 'Process inspection unavailable; normal macOS process access required')
    require(running.returncode == 1, 'OpenEmu is already running; this test will not close it')
    before = locator_snapshot()
    original = fingerprint(app)
    work = Path(tempfile.mkdtemp(prefix='openemu-input-ui-', dir='/private/tmp')).resolve()
    print('Retained private permission-UI workspace:', work, flush=True)
    library = work / 'InputMonitoringAppDriver.dylib'
    compilation = run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-fmodules',
                       '-fmodules-cache-path=' + str(work / 'ModuleCache'), '-Wall', '-Wextra', '-Werror',
                       sys.argv[2], '-framework', 'Foundation', '-framework', 'AppKit', '-o', str(library)], timeout=60)
    require(compilation.returncode == 0, compilation.stderr.decode(errors='replace'))
    signed = run(['/usr/bin/codesign', '--force', '--sign', '-', str(library)])
    require(signed.returncode == 0, 'Cannot sign private test driver')
    home = work / 'Private Home'
    home.mkdir()
    data = work / 'Data'
    # The driver creates this only AFTER permission methods are replaced. If
    # library injection is rejected, a missing explicit profile aborts startup
    # before any permission request instead of opening the user's data.
    require(not data.exists() and not data.is_symlink(), 'Fail-closed profile path must not exist')
    marker = str(uuid.uuid4()).upper()
    env = os.environ.copy()
    env.pop('XCTestConfigurationFilePath', None)
    env.update({'DYLD_INSERT_LIBRARIES': str(library), 'OE_DISABLE_UPDATE_CHECK': 'YES',
                'CFFIXED_USER_HOME': str(home), 'OE_PERMISSION_TEST_WORKSPACE': str(work),
                'OE_PERMISSION_TEST_MARKER': marker})
    try:
        with (work / 'app.log').open('wb') as log:
            process = subprocess.Popen([str(app / 'Contents/MacOS/OpenEmu'), '--data-folder', str(data),
                '-OEIntelSentryCrashReportingPrompted', 'YES', '-OEIntelSentryCrashReportingEnabled', 'NO',
                '-OESkipDiscGuideMessageKey', 'YES', '-SUEnableAutomaticChecks', 'NO'],
                env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            owned.append(process)
            print('Started owned permission-UI fixture PID', process.pid, flush=True)
            status = process.wait(timeout=35)
        events = work / 'permission-driver-events.txt'
        text = events.read_text() if events.exists() else ''
        require('FAIL ' not in text, 'Test driver reported failure; see ' + str(events))
        require(status == 0, 'Test app did not exit normally; see ' + str(work / 'app.log'))
        for expected in ('PERMISSION_STUBS_INSTALLED_BEFORE_PRIVATE_PROFILE_CREATION',
                         'ACTUAL_PERMISSION_ALERT_PRESENTED', 'APPLICATION_DID_FINISH_LAUNCHING',
                         'SIMULATED_GRANT_RECHECKED', 'GRANTED_SHEET_COMPLETED_ONCE',
                         'PASS_ACTUAL_PERMISSION_SHEET_NO_FLICKER', 'APPLICATION_WILL_TERMINATE'):
            require(text.splitlines().count(expected) == 1, 'Missing or repeated evidence: ' + expected)
        for click in range(1, 6):
            require(text.splitlines().count('DENIED_CLICK_{}_SAME_ALERT'.format(click)) == 1,
                    'Actual denied button click {} not verified'.format(click))
        with (data / 'Settings.plist').open('rb') as stream:
            settings = plistlib.load(stream)
        require(settings.get('OEPermissionRegressionSentinel') == marker, 'Private settings sentinel changed')
        require(settings.get('OEInputMonitoringAlertSuppressed') is True, 'Recheck changed dismissal preference')
        require((data / '.oe_credentials').read_bytes() == b'synthetic-credential-sentinel-no-keychain-migration',
                'Private credential sentinel changed')
    finally:
        for process in owned:
            stop_owned(process)
        require(locator_snapshot() == before, 'Real folder locator changed; no automatic restoration attempted')
        require(fingerprint(app) == original, 'Original application files changed during test')
    print('PASS: five real denied Check Again clicks retain one OEAlert/window; simulated grant closes it once', flush=True)
    print('PASS: app and real folder locators unchanged; no real TCC request, Keychain migration or core builds', flush=True)
    print('NOTE: simulated permission states do not prove a Finder-launched app has actual macOS input access', flush=True)

try:
    main()
except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
    print('FAIL:', error, file=sys.stderr, flush=True)
    sys.exit(1)
finally:
    for process in owned:
        stop_owned(process)
PY
