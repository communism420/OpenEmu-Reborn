#!/usr/bin/env bash
# Compile isolated Foundation/AppKit-entrypoint fixtures only. No OpenEmu/core
# build or app launch; all profile/defaults domains are private to these tests.
set -euo pipefail
language_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
language_repository="$(cd "$language_tests_directory/../.." && pwd)"
language_workspace="$(mktemp -d /private/tmp/openemu-interface-language.XXXXXX)"
echo "Retained interface-language fixture: $language_workspace"
[[ "$(id -u)" != 0 ]] || { echo 'Run as an ordinary user for write-failure checks.' >&2; exit 1; }

xcrun clang -c -fobjc-arc -fmodules -Wall -Wextra -Werror -mmacosx-version-min=11.0 \
    "-fmodules-cache-path=$language_workspace/ClangModuleCache" \
    "$language_repository/OpenEmu-SDK/OpenEmuBase/OEPreferences.m" \
    -o "$language_workspace/OEPreferences.o"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "$language_workspace/SwiftModuleCache" -I "$language_tests_directory" \
    "$language_repository/OpenEmu/OEInterfaceLanguage.swift" \
    "$language_tests_directory/InterfaceLanguageSmokeTests.swift" "$language_workspace/OEPreferences.o" \
    -framework Foundation -o "$language_workspace/preferences-language-tests"
mkdir "$language_workspace/profiles"
"$language_workspace/preferences-language-tests" "$language_workspace/profiles"

mkdir -p "$language_workspace/Probe.app/Contents/MacOS" "$language_workspace/Probe.app/Contents/Resources"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "$language_workspace/SwiftModuleCache" \
    "$language_repository/OpenEmu/OEInterfaceLanguage.swift" \
    "$language_repository/OpenEmu/OpenEmuLaunch.swift" \
    "$language_tests_directory/InterfaceLanguageEntrypointProbe.swift" \
    -framework AppKit -o "$language_workspace/Probe.app/Contents/MacOS/Probe"
for language_table in "$language_repository"/OpenEmu/*.lproj; do
    cp -R "$language_table" "$language_workspace/Probe.app/Contents/Resources/"
done
/usr/bin/python3 -B - "$language_workspace" <<'PY'
from pathlib import Path
import os
import plistlib
import subprocess
import sys
import uuid

work = Path(sys.argv[1]).resolve()
app = work / 'Probe.app'
identifier = 'org.openemu.InterfaceLanguageFixture.' + uuid.uuid4().hex
with (app / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump({'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Probe',
                  'CFBundleName': 'Probe', 'CFBundlePackageType': 'APPL', 'CFBundleDevelopmentRegion': 'en'}, stream)
for localization in sorted((app / 'Contents/Resources').glob('*.lproj')):
    code = localization.stem
    folder = work / ('entry-' + code)
    folder.mkdir()
    for name, value in [('.openemu-data-folder.plist', {'version': 1, 'identifier': str(uuid.uuid4())}),
                        ('Settings.plist', {'OEInterfaceLanguage': code})]:
        with (folder / name).open('wb') as stream:
            plistlib.dump(value, stream)
    # Use actual current translations; this is a selection/ordering test, not
    # an assertion about a translator's particular choice of words.
    table = localization / 'Localizable.strings'
    if not table.exists() and code == 'fr-CA':
        table = app / 'Contents/Resources/fr.lproj/Localizable.strings'
    expected = plistlib.loads(table.read_bytes())['Cancel']
    environment = {k: v for k, v in os.environ.items() if k not in ('GH_TOKEN', 'GITHUB_TOKEN', 'GH_DEBUG', 'XCTestConfigurationFilePath')}
    environment['OPENEMU_LANGUAGE_EXPECTED'] = expected
    subprocess.run([str(app / 'Contents/MacOS/Probe'), '--data-folder', str(folder)], env=environment, check=True, timeout=20)
    environment['OPENEMU_LANGUAGE_EXPECTED'] = 'Cancel'
    subprocess.run([str(app / 'Contents/MacOS/Probe'), '--data-folder', str(folder), '-AppleLanguages', '(en)'],
                   env=environment, check=True, timeout=20)
print('PASS: production entrypoint applies profile language before AppKit; explicit AppleLanguages wins')
PY
