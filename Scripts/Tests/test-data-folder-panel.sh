#!/usr/bin/env bash
# Native modal first-run/recovery panels, in the requested languages. Compile only
# the current host source and this tiny harness against an existing SDK binary.
# OE_DATA_FOLDER_PANEL_SOURCE can point to a preserved source for negative tests.
set -euo pipefail

if [[ $# != 1 || ( "$1" != --standalone && ! -d "$1/Contents/Frameworks/OpenEmuBase.framework" ) ]]; then
    echo "Usage: bash $0 /absolute/path/to/OpenEmu.app | --standalone" >&2
    exit 2
fi
panel_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
panel_repository="$(cd "$panel_tests_directory/../.." && pwd)"
panel_workspace="$(mktemp -d /private/tmp/openemu-data-folder-panel.XXXXXX)"
panel_link_arguments=()
if [[ "$1" != --standalone ]]; then
panel_app="$(cd "$1" && pwd)"
panel_frameworks="$panel_app/Contents/Frameworks"
panel_modules="$panel_frameworks"
if [[ ! -f "$panel_modules/OpenEmuBase.framework/Modules/module.modulemap" ]]; then
    panel_modules="$panel_repository/tmp/agent/data-folder-derived/Build/Products/Release"
fi
panel_packaged_uuid="$(xcrun dwarfdump --uuid "$panel_frameworks/OpenEmuBase.framework/OpenEmuBase" | awk '{print $2, $3}')"
panel_compiled_uuid="$(xcrun dwarfdump --uuid "$panel_modules/OpenEmuBase.framework/OpenEmuBase" | awk '{print $2, $3}')"
[[ -n "$panel_packaged_uuid" && "$panel_packaged_uuid" == "$panel_compiled_uuid" ]] || { echo "OpenEmuBase UUID mismatch" >&2; exit 1; }
panel_link_arguments=(-F "$panel_modules" -framework OpenEmuBase -Xlinker -rpath -Xlinker "$panel_frameworks")
else
    # Compile the real small storage implementation in isolation. This mode
    # does not combine a packaged framework with headers from another build.
    for panel_source in OEStoragePaths OEPreferences; do
        xcrun clang -c -fobjc-arc -fmodules \
            "-fmodules-cache-path=$panel_workspace/ClangModuleCache" \
            -Wall -Wextra -Werror -mmacosx-version-min=11.0 \
            "$panel_repository/OpenEmu-SDK/OpenEmuBase/$panel_source.m" \
            -o "$panel_workspace/$panel_source.o"
    done
    panel_link_arguments=(-I "$panel_tests_directory" "$panel_workspace/OEStoragePaths.o" "$panel_workspace/OEPreferences.o")
fi
panel_bundle="$panel_workspace/DataFolderPanelTests.app"
mkdir -p "$panel_bundle/Contents/MacOS" "$panel_bundle/Contents/Resources/ru.lproj"
# The production source plist contains unresolved Xcode substitutions and
# document/URL registrations unrelated to this fixture. Use a complete test
# identity instead. This packaging repair alone does not establish the cause
# of an Intel CI stall in AppKit's remote panel service.
cp "$panel_tests_directory/DataFolderPanelTests-Info.plist" "$panel_bundle/Contents/Info.plist"
plutil -lint "$panel_bundle/Contents/Info.plist"
for panel_locale in "$panel_repository"/OpenEmu/*.lproj; do
    [[ -f "$panel_locale/Localizable.strings" ]] || continue
    mkdir -p "$panel_bundle/Contents/Resources/$(basename "$panel_locale")"
    cp "$panel_locale/Localizable.strings" "$panel_bundle/Contents/Resources/$(basename "$panel_locale")/Localizable.strings"
done
cp "${OE_DATA_FOLDER_PANEL_SOURCE:-$panel_repository/OpenEmu/OEDataFolderSetup.swift}" "$panel_workspace/OEDataFolderSetup.swift"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "$panel_workspace/ModuleCache" \
    "$panel_workspace/OEDataFolderSetup.swift" "$panel_tests_directory/DataFolderPanelSmokeTests.swift" \
    -framework AppKit "${panel_link_arguments[@]}" \
    -o "$panel_bundle/Contents/MacOS/data-folder-panel-tests"

# Normalize the completed fixture's signature on both CPUs. Ad-hoc signing
# uses no certificate, private key, entitlement or system permission changes.
codesign --force --sign - --timestamp=none "$panel_bundle"
codesign --verify --deep --strict "$panel_bundle"

panel_failed=0
for panel_language in ${OE_PANEL_TEST_LANGUAGES:-ru en}; do
    mkdir -p "$panel_workspace/$panel_language/Library/Preferences"
    echo "Starting native panel fixture: $panel_language (45-second deadline)"
    CFFIXED_USER_HOME="$panel_workspace/$panel_language" OE_PANEL_TEST_LANGUAGE="$panel_language" \
        python3 - "$panel_bundle/Contents/MacOS/data-folder-panel-tests" "$panel_language" <<'PY' || panel_failed=1
import subprocess
import sys
import time

executable, language = sys.argv[1:]
process = subprocess.Popen([executable, '-AppleLanguages', f'({language})'])
deadline = time.monotonic() + 45
try:
    # Reserve the last five seconds of the existing deadline for a stack
    # sample. A hung AppKit initialization must fail with useful evidence,
    # rather than only printing "Alarm clock" after silently dying.
    status = process.wait(timeout=40)
except subprocess.TimeoutExpired:
    print(f'NOTE: {language} native panel fixture is near its deadline; sampling PID {process.pid}', flush=True)
    try:
        subprocess.run(['/usr/bin/sample', str(process.pid), '1', '10'], timeout=4, check=False)
    except subprocess.TimeoutExpired:
        print('NOTE: stack sampling exceeded its four-second diagnostic limit', flush=True)
    except OSError as error:
        print(f'NOTE: stack sampling unavailable: {error}', flush=True)
    try:
        status = process.wait(timeout=max(0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        print(f'FAIL: {language} native panel fixture exceeded its 45-second deadline', flush=True)
        process.kill()
        process.wait()
        sys.exit(1)
sys.exit(status if status >= 0 else 1)
PY
done
echo "Test-only source, bundle and isolated homes retained at $panel_workspace"
exit "$panel_failed"
