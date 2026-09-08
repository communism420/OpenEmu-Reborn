#!/usr/bin/env bash
# Native modal first-run/recovery panels, in Russian and English. Compile only
# the current host source and this tiny harness against an existing SDK binary.
# OE_DATA_FOLDER_PANEL_SOURCE can point to a preserved source for negative tests.
set -euo pipefail

if [[ $# != 1 || ! -d "$1/Contents/Frameworks/OpenEmuBase.framework" ]]; then
    echo "Usage: bash $0 /absolute/path/to/OpenEmu.app" >&2
    exit 2
fi
panel_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
panel_repository="$(cd "$panel_tests_directory/../.." && pwd)"
panel_app="$(cd "$1" && pwd)"
panel_frameworks="$panel_app/Contents/Frameworks"
panel_modules="$panel_frameworks"
if [[ ! -f "$panel_modules/OpenEmuBase.framework/Modules/module.modulemap" ]]; then
    panel_modules="$panel_repository/tmp/agent/data-folder-derived/Build/Products/Release"
fi
panel_packaged_uuid="$(xcrun dwarfdump --uuid "$panel_frameworks/OpenEmuBase.framework/OpenEmuBase" | awk '{print $2, $3}')"
panel_compiled_uuid="$(xcrun dwarfdump --uuid "$panel_modules/OpenEmuBase.framework/OpenEmuBase" | awk '{print $2, $3}')"
[[ -n "$panel_packaged_uuid" && "$panel_packaged_uuid" == "$panel_compiled_uuid" ]] || { echo "OpenEmuBase UUID mismatch" >&2; exit 1; }
panel_workspace="$(mktemp -d /private/tmp/openemu-data-folder-panel.XXXXXX)"
panel_bundle="$panel_workspace/DataFolderPanelTests.app"
mkdir -p "$panel_bundle/Contents/MacOS" "$panel_bundle/Contents/Resources/ru.lproj"
cp "$panel_app/Contents/Info.plist" "$panel_bundle/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string org.openemu.tests.DataFolderPanel "$panel_bundle/Contents/Info.plist"
plutil -replace CFBundleExecutable -string data-folder-panel-tests "$panel_bundle/Contents/Info.plist"
plutil -replace NSPrincipalClass -string NSApplication "$panel_bundle/Contents/Info.plist"
for panel_key in NSMainNibFile NSMainStoryboardFile; do
    if plutil -extract "$panel_key" raw -o - "$panel_bundle/Contents/Info.plist" >/dev/null 2>&1; then
        plutil -remove "$panel_key" "$panel_bundle/Contents/Info.plist"
    fi
done
cp "$panel_repository/OpenEmu/ru.lproj/Localizable.strings" "$panel_bundle/Contents/Resources/ru.lproj/Localizable.strings"
cp "${OE_DATA_FOLDER_PANEL_SOURCE:-$panel_repository/OpenEmu/OEDataFolderSetup.swift}" "$panel_workspace/OEDataFolderSetup.swift"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "$panel_workspace/ModuleCache" -F "$panel_modules" \
    "$panel_workspace/OEDataFolderSetup.swift" "$panel_tests_directory/DataFolderPanelSmokeTests.swift" \
    -framework AppKit -framework OpenEmuBase \
    -Xlinker -rpath -Xlinker "$panel_frameworks" \
    -o "$panel_bundle/Contents/MacOS/data-folder-panel-tests"

panel_failed=0
for panel_language in ${OE_PANEL_TEST_LANGUAGES:-ru en}; do
    mkdir -p "$panel_workspace/$panel_language/Library/Preferences"
    CFFIXED_USER_HOME="$panel_workspace/$panel_language" OE_PANEL_TEST_LANGUAGE="$panel_language" \
        perl -e 'alarm 45; exec @ARGV' "$panel_bundle/Contents/MacOS/data-folder-panel-tests" \
        -AppleLanguages "($panel_language)" || panel_failed=1
done
echo "Test-only source, bundle and isolated homes retained at $panel_workspace"
exit "$panel_failed"
