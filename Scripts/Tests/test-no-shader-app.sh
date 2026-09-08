#!/usr/bin/env bash
# Existing app only: real shader preferences action, all bundled system stores,
# localized menu identity and persistence across private-process relaunches.
# No ROMs, core launches/builds, real settings writes or Trash operations.
set -euo pipefail
if [[ $# != 1 || "$1" == --help || "$1" == -h ]]; then
    echo "Usage: bash $0 /absolute/path/OpenEmu.app"
    [[ $# == 1 && ( "$1" == --help || "$1" == -h ) ]] && exit 0
    exit 2
fi
shader_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$1" "$shader_tests_directory/NoShaderAppDriver.m" <<'PY'
import hashlib
import os
from pathlib import Path
import plistlib
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

def read_plist(path):
    with path.open('rb') as stream:
        return plistlib.load(stream)

def write_plist(path, value):
    with path.open('wb') as stream:
        plistlib.dump(value, stream)

def locators():
    result = {}
    for domain in ('org.openemu.OpenEmu', 'org.openemu.OpenEmu.debug'):
        for key in ('OEDataFolderBookmark', 'OEDataFolderIdentifier', 'OEDataFolderPath'):
            value = run(['/usr/bin/defaults', 'read', domain, key])
            require(value.returncode in (0, 1), 'Cannot safely inspect real folder locators')
            result[(domain, key)] = (value.returncode, hashlib.sha256(value.stdout).digest())
    return result

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
    require(running.returncode in (0, 1), 'Process inspection unavailable; normal macOS process access is required')
    require(running.returncode == 1, 'OpenEmu is already running; this test will not close it')
    identifiers = sorted({read_plist(path)['OESystemIdentifier'] for path in
                          (app / 'Contents/PlugIns/Systems').glob('*.oesystemplugin/Contents/Info.plist')})
    require(identifiers and all(isinstance(item, str) and item.startswith('openemu.system.') for item in identifiers),
            'Cannot inventory bundled system identifiers')
    original_locators = locators()
    work = Path(tempfile.mkdtemp(prefix='openemu-no-shader-', dir='/private/tmp')).resolve()
    print('Retained private No Shader workspace:', work, flush=True)
    write_plist(work / 'bundled-system-identifiers.plist', identifiers)
    library = work / 'NoShaderAppDriver.dylib'
    compilation = run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-fmodules',
                       '-fmodules-cache-path=' + str(work / 'ModuleCache'), '-Wall', '-Wextra', '-Werror',
                       sys.argv[2], '-framework', 'Foundation', '-framework', 'AppKit', '-o', str(library)], timeout=60)
    require(compilation.returncode == 0, compilation.stderr.decode(errors='replace'))
    require(run(['/usr/bin/codesign', '--force', '--sign', '-', str(library)]).returncode == 0, 'Cannot sign private test driver')
    data = work / 'Data'
    data.mkdir()
    identity = str(uuid.uuid4()).upper()
    write_plist(data / '.openemu-data-folder.plist', {'version': 1, 'identifier': identity})
    write_plist(data / 'Settings.plist', {'setupAssistantFinished': True, 'OENoShaderSentinel': identity})
    credentials = b'synthetic-test-credential-sentinel-prevents-keychain-migration'
    (data / '.oe_credentials').write_bytes(credentials)
    (work / 'Private Home').mkdir()
    events = work / 'shader-driver-events.txt'
    try:
        for mode, language in (('per-system', 'en'), ('global', 'ru'), ('re-enable', 'ru'), ('final-reload', 'en')):
            log = (work / (mode + '.log')).open('wb')
            logs.append(log)
            env = os.environ.copy()
            env.update({'DYLD_INSERT_LIBRARIES': str(library), 'OE_DISABLE_UPDATE_CHECK': 'YES',
                        'CFFIXED_USER_HOME': str(work / 'Private Home'), 'OE_SHADER_TEST_WORKSPACE': str(work),
                        'OE_SHADER_TEST_DATA_ROOT': str(data), 'OE_SHADER_TEST_MODE': mode,
                        'OE_SHADER_TEST_TITLE': 'Без шейдера' if language == 'ru' else 'No Shader'})
            process = subprocess.Popen([str(app / 'Contents/MacOS/OpenEmu'), '--data-folder', str(data),
                '-AppleLanguages', '(' + language + ')', '-AppleLocale', 'ru_RU' if language == 'ru' else 'en_US',
                '-OEIntelSentryCrashReportingPrompted', 'YES', '-OEIntelSentryCrashReportingEnabled', 'NO',
                '-SUEnableAutomaticChecks', 'NO'], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            owned.append(process)
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline:
                text = events.read_text() if events.exists() else ''
                require('FAIL ' not in text, 'Injected regression failed; see ' + str(events))
                require(process.poll() is None, 'App exited/crashed before shader verification; see ' + str(log.name))
                if mode + ' NO_SHADER_REGRESSION_PASS_APP_ALIVE' in text:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError('No Shader regression timed out; see ' + str(log.name))
            stop_owned(process)
            settings = read_plist(data / 'Settings.plist')
            require(settings.get('OENoShaderSentinel') == identity, 'Unrelated fixture setting changed')
            require((data / '.oe_credentials').read_bytes() == credentials, 'Unrelated fixture credentials changed')
            if mode == 'per-system':
                require(all(settings.get('videoShader.' + system) == 'No Shader' for system in identifiers),
                        'Per-system No Shader choices were not written for every bundled system')
            else:
                expected = 'No Shader' if mode == 'global' else 'Pixellate'
                require(settings.get('videoShader') == expected, 'Global canonical shader choice was not persisted')
                require(all('videoShader.' + system not in settings and 'videoShader.' + system + '.preset' not in settings
                            for system in identifiers), 'Global selection left per-system overrides')
            print('PASS:', mode, '(' + str(len(identifiers)) + ' bundled systems, ' + language + ')', flush=True)
    finally:
        for process in owned:
            stop_owned(process)
        require(locators() == original_locators, 'Real folder locator changed; no automatic restoration attempted')
    print('PASS: actual global picker/action, per-system and global relaunch persistence, re-enable, English/Russian identity', flush=True)
    print('PASS: no game documents, ROM/core launches, core builds, or real user settings writes', flush=True)

try:
    main()
except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
    print('FAIL:', error, file=sys.stderr, flush=True)
    sys.exit(1)
finally:
    for process in owned:
        stop_owned(process)
    for log in logs:
        log.close()
PY
