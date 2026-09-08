#!/usr/bin/env bash
# Private clone of an already-built Release app: unchanged executable and
# frameworks, unique bundle identity for native panel preferences, memory-only
# bootstrap defaults, private framework home, real native layout and Cancel.
# No selected folder, library, preferences reset, ROMs or core/app builds.
set -euo pipefail
if [[ $# != 1 || "$1" == --help || "$1" == -h ]]; then
    echo "Usage: bash $0 /absolute/path/OpenEmu.app"
    [[ $# == 1 && ( "$1" == --help || "$1" == -h ) ]] && exit 0
    exit 2
fi
panel_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$1" "$panel_tests_directory/DataFolderPanelAppDriver.m" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import uuid

owned = []
logs = []

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def run(arguments, timeout=10):
    return subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)

def real_defaults_snapshot():
    result = {}
    for domain in ('org.openemu.OpenEmu', 'org.openemu.OpenEmu.debug'):
        for key in ('OEDataFolderBookmark', 'OEDataFolderIdentifier', 'OEDataFolderPath', 'OEDataFolderLastPath'):
            value = run(['/usr/bin/defaults', 'read', domain, key])
            require(value.returncode in (0, 1), 'Cannot inspect real folder locators safely')
            result[domain + ':' + key] = [value.returncode, hashlib.sha256(value.stdout).hexdigest()]
        exported = run(['/usr/bin/defaults', 'export', domain, '-'])
        require(exported.returncode in (0, 1), 'Cannot inspect real app defaults safely')
        contents = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}
        canonical = plistlib.dumps(contents, sort_keys=True)
        result[domain + ':whole-domain'] = [exported.returncode, hashlib.sha256(canonical).hexdigest()]
        for key, value in contents.items():
            result[domain + ':stored:' + key] = hashlib.sha256(plistlib.dumps({'value': value}, sort_keys=True)).hexdigest()
    return result

def executable_uuid(path):
    result = run(['/usr/bin/dwarfdump', '--uuid', str(path)])
    require(result.returncode == 0, 'Cannot inspect executable UUID')
    return re.findall(r'UUID:\s+([A-Fa-f0-9-]+)\s+\(([^)]+)\)', result.stdout.decode())

def source_fingerprint(app):
    paths = ('Contents/MacOS/OpenEmu', 'Contents/Info.plist', 'Contents/_CodeSignature/CodeResources')
    return {path: hashlib.sha256((app / path).read_bytes()).hexdigest() for path in paths}

def record_hashes(path, values):
    # Key names + hashes only: never save real preference values or bookmarks.
    path.write_text(json.dumps(values, indent=2, sort_keys=True))

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
    require(info.get('CFBundleIdentifier') == 'org.openemu.OpenEmu' and info.get('CFBundleExecutable') == 'OpenEmu',
            'Expected an already-built Release app')
    running = run(['/usr/bin/pgrep', '-x', 'OpenEmu'])
    require(running.returncode in (0, 1), 'Process inspection unavailable; normal macOS process access required')
    require(running.returncode == 1, 'OpenEmu is already running; this test will not close it')
    work = Path(tempfile.mkdtemp(prefix='openemu-first-panel-', dir='/private/tmp')).resolve()
    print('Retained private first-run panel workspace:', work, flush=True)
    before = real_defaults_snapshot()
    record_hashes(work / 'real-defaults-before-hashes.json', before)
    original_fingerprint = source_fingerprint(app)
    original_uuid = executable_uuid(app / 'Contents/MacOS/OpenEmu')
    require(original_uuid, 'Source executable must contain a UUID')
    private_app = work / 'Fixture.app'
    copied = run(['/bin/cp', '-cR', str(app), str(private_app)], timeout=60)
    require(copied.returncode == 0, 'APFS clone of the private test app failed: ' + copied.stderr.decode(errors='replace'))
    private_identifier = 'org.openemu.FirstPanelFixture.' + uuid.uuid4().hex
    info['CFBundleIdentifier'] = private_identifier
    with (private_app / 'Contents/Info.plist').open('wb') as stream:
        plistlib.dump(info, stream)
    signed_app = run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none',
                      '--preserve-metadata=entitlements,flags', str(private_app)], timeout=30)
    require(signed_app.returncode == 0, 'Cannot sign the private outer app copy')
    require(executable_uuid(private_app / 'Contents/MacOS/OpenEmu') == original_uuid, 'Private executable UUID differs from the final build')
    require(source_fingerprint(app) == original_fingerprint, 'Original application changed while preparing test copy')
    print('Private native-preferences identity:', private_identifier, '; executable UUID:', original_uuid, flush=True)
    library = work / 'DataFolderPanelAppDriver.dylib'
    compilation = run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-fmodules',
                       '-fmodules-cache-path=' + str(work / 'ModuleCache'), '-Wall', '-Wextra', '-Werror',
                       sys.argv[2], '-framework', 'Foundation', '-framework', 'AppKit', '-o', str(library)], timeout=60)
    require(compilation.returncode == 0, compilation.stderr.decode(errors='replace'))
    require(run(['/usr/bin/codesign', '--force', '--sign', '-', str(library)]).returncode == 0, 'Cannot sign private test driver')
    events = work / 'panel-driver-events.txt'
    try:
        for language in ('en', 'ru'):
            private_home = work / language
            private_home.mkdir()
            env = os.environ.copy()
            env.pop('XCTestConfigurationFilePath', None)
            env.update({'DYLD_INSERT_LIBRARIES': str(library), 'OE_DISABLE_UPDATE_CHECK': 'YES',
                        'CFFIXED_USER_HOME': str(private_home), 'OE_PANEL_TEST_WORKSPACE': str(work),
                        'OE_PANEL_TEST_LANGUAGE': language})
            log = (work / (language + '.log')).open('wb')
            logs.append(log)
            process = subprocess.Popen([str(private_app / 'Contents/MacOS/OpenEmu'),
                '-AppleLanguages', '(' + language + ')', '-AppleLocale', 'ru_RU' if language == 'ru' else 'en_US',
                '-OEIntelSentryCrashReportingPrompted', 'YES', '-OEIntelSentryCrashReportingEnabled', 'NO',
                '-SUEnableAutomaticChecks', 'NO'], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            owned.append(process)
            status = process.wait(timeout=30)
            text = events.read_text() if events.exists() else ''
            require('FAIL ' not in text, 'Injected panel regression failed; see ' + str(events))
            require(status == 0, 'Cancel must exit normally before library setup; see ' + str(log.name))
            for marker in ('MEMORY_DEFAULTS_INSTALLED_BEFORE_BOOTSTRAP', 'BOOTSTRAP_SUITE_REDIRECTED_TO_MEMORY', 'ACTUAL_FIRST_RUN_PANEL_VISIBLE',
                           'PRIVATE_BOOTSTRAP_AND_MODAL_GEOMETRY_VERIFIED'):
                require(language + ' ' + marker in text, 'Missing actual startup/modal evidence: ' + marker)
            require(language + ' NATIVE_CANCEL_CLICKED' in text or language + ' NATIVE_CANCEL_ACTION_SENT' in text,
                    'This private panel must exit through its native Cancel action')
            require(sum(line.startswith(language + ' SAMPLE ') for line in text.splitlines()) >= 12,
                    'Need repeated checks after native modal layout, not just a pre-display frame')
            for forbidden in ('.openemu-data-folder.plist', 'Settings.plist', 'Library.storedata', '.oe_credentials'):
                require(not list(private_home.rglob(forbidden)), 'Cancelling first-run created app data: ' + forbidden)
            if language + ' REMOTE_BUTTON_FRAMES_UNAVAILABLE' in text:
                print('NOTE:', language, 'native button frames are remote-hosted and unavailable to local view traversal', flush=True)
            print('PASS:', language, 'ordinary first-run modal fits over 12 turns; native Cancel exits without data setup', flush=True)
    finally:
        for process in owned:
            stop_owned(process)
        after = real_defaults_snapshot()
        record_hashes(work / 'real-defaults-after-hashes.json', after)
        changed_keys = sorted(key for key in set(before) | set(after) if before.get(key) != after.get(key))
        require(not changed_keys, 'Real app defaults/locators changed (key names only): ' + ', '.join(changed_keys) + '; no restoration attempted')
        require(source_fingerprint(app) == original_fingerprint, 'Original final application changed during tests')
    print('PASS: real app defaults and locators unchanged; no selected folder, library, ROM or builds', flush=True)

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
