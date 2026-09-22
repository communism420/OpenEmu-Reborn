#!/usr/bin/env bash
# Compile only the shared resolver and a private host/helper subprocess fixture.
# No emulation, game library, permissions or persistent user preferences.
set -euo pipefail
test_repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_workspace="$(mktemp -d /private/tmp/openemu-helper-localization.XXXXXX)"
test_bundle="$test_workspace/Host.app"
mkdir -p "$test_bundle/Contents/MacOS" "$test_bundle/Contents/Resources" "$test_workspace/home/Library/Preferences"
for test_locale in "$test_repository"/OpenEmu/*.lproj; do
    [[ -f "$test_locale/Localizable.strings" ]] || continue
    mkdir -p "$test_bundle/Contents/Resources/$(basename "$test_locale")"
    cp "$test_locale/Localizable.strings" "$test_bundle/Contents/Resources/$(basename "$test_locale")/Localizable.strings"
done
# Also reproduce fr-CA's partial resource folder, which must fall back to fr.
mkdir -p "$test_bundle/Contents/Resources/fr-CA.lproj"
cp "$test_repository/OpenEmu/fr-CA.lproj/InfoPlist.strings" "$test_bundle/Contents/Resources/fr-CA.lproj/InfoPlist.strings"
for test_executable in Host Helper; do
    test_plist="$test_workspace/$test_executable.plist"
    plutil -create xml1 "$test_plist"
    plutil -insert CFBundleIdentifier -string "org.openemu.tests.HelperLocalization.$test_executable" "$test_plist"
    plutil -insert CFBundleExecutable -string "$test_executable" "$test_plist"
    plutil -insert CFBundleDevelopmentRegion -string en "$test_plist"
    xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror -mmacosx-version-min=11.0 \
        "-fmodules-cache-path=$test_workspace/ModuleCache" \
        -I "$test_repository/OpenEmuKit/Source/OpenEmuKitPrivate" \
        "$test_repository/Scripts/Tests/HelperLocalizationSmokeTests.m" \
        -framework Foundation -Wl,-sectcreate,__TEXT,__info_plist,"$test_plist" \
        -o "$test_bundle/Contents/MacOS/$test_executable"
done
cp "$test_workspace/Host.plist" "$test_bundle/Contents/Info.plist"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "$test_workspace/ModuleCache" \
    -I "$test_repository/OpenEmuKit/Source" \
    "$test_repository/Scripts/Tests/HelperLocalizationSwiftProbe.swift" \
    -framework Foundation -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$test_workspace/Helper.plist" \
    -o "$test_bundle/Contents/MacOS/SwiftHelper"
CFFIXED_USER_HOME="$test_workspace/home" OE_LOCALIZATION_SOURCE="$test_repository/OpenEmu" \
    perl -e 'alarm 30; exec @ARGV' "$test_bundle/Contents/MacOS/Host"
CFFIXED_USER_HOME="$test_workspace/home" OE_LOCALIZATION_SOURCE="$test_repository/OpenEmu" \
    perl -e 'alarm 10; exec @ARGV' "$test_bundle/Contents/MacOS/SwiftHelper" -AppleLanguages '(ru)'
cp "$test_bundle/Contents/MacOS/Helper" "$test_workspace/Standalone"
CFFIXED_USER_HOME="$test_workspace/home" \
    perl -e 'alarm 10; exec @ARGV' "$test_workspace/Standalone" --fixture-standalone -AppleLanguages '(ru)'
echo "Private helper localization fixture retained at $test_workspace"
