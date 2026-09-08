#!/usr/bin/env bash
# Test production shader selection code against an already built application's
# frameworks/resources. Only this small harness is compiled; no app/core build.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! -d "$1/Contents/Frameworks/OpenEmuKit.framework" ]]; then
    echo "Usage: bash $0 /absolute/path/to/OpenEmu.app [matching-built-frameworks-directory]" >&2
    exit 2
fi
no_shader_tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
no_shader_repo="$(cd "$no_shader_tests/../.." && pwd)"
no_shader_app="$(cd "$1" && pwd)"
no_shader_frameworks="$no_shader_app/Contents/Frameworks"
no_shader_compile_frameworks="${2:-$no_shader_frameworks}"
if [[ $# == 1 && ! -d "$no_shader_compile_frameworks/OpenEmuKit.framework/Modules/OpenEmuKit.swiftmodule" ]]; then
    no_shader_compile_frameworks="$no_shader_repo/tmp/agent/data-folder-derived/Build/Products/Release"
fi
if [[ ! -d "$no_shader_compile_frameworks/OpenEmuKit.framework/Modules/OpenEmuKit.swiftmodule" ]]; then
    echo "Swift modules are missing; pass the matching built frameworks directory as the second argument." >&2
    exit 2
fi
no_shader_compile_frameworks="$(cd "$no_shader_compile_frameworks" && pwd)"
# Packaged apps may strip Swift module metadata. Optional compile-time modules
# must describe the exact same binaries; runtime always uses the packaged app.
for no_shader_framework in OpenEmuKit OpenEmuBase OpenEmuSystem OpenEmuShaders; do
    no_shader_packaged_uuid="$(xcrun dwarfdump --uuid "$no_shader_frameworks/$no_shader_framework.framework/$no_shader_framework" | awk '{print $2, $3}')"
    no_shader_compiled_uuid="$(xcrun dwarfdump --uuid "$no_shader_compile_frameworks/$no_shader_framework.framework/$no_shader_framework" | awk '{print $2, $3}')"
    if [[ -z "$no_shader_packaged_uuid" || "$no_shader_packaged_uuid" != "$no_shader_compiled_uuid" ]]; then
        echo "Framework UUID mismatch: $no_shader_framework" >&2
        exit 1
    fi
done
no_shader_workspace="$(mktemp -d /private/tmp/openemu-no-shader-selection.XXXXXX)"
no_shader_bundle="$no_shader_workspace/NoShaderSelectionTests.bundle"
mkdir -p "$no_shader_bundle/Contents/MacOS" "$no_shader_bundle/Contents/Resources/ru.lproj" "$no_shader_workspace/profile"

# Give NSLocalizedString its own main bundle. No installed application or real
# defaults domain is launched or modified, and the selected data root is private.
cp "$no_shader_app/Contents/Info.plist" "$no_shader_bundle/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string org.openemu.tests.NoShaderSelection "$no_shader_bundle/Contents/Info.plist"
plutil -replace CFBundleExecutable -string no-shader-selection-tests "$no_shader_bundle/Contents/Info.plist"
plutil -replace CFBundlePackageType -string BNDL "$no_shader_bundle/Contents/Info.plist"
for no_shader_key in NSPrincipalClass NSMainNibFile NSMainStoryboardFile; do
    if plutil -extract "$no_shader_key" raw -o - "$no_shader_bundle/Contents/Info.plist" >/dev/null 2>&1; then
        plutil -remove "$no_shader_key" "$no_shader_bundle/Contents/Info.plist"
    fi
done
ditto "$no_shader_app/Contents/Resources/Shaders" "$no_shader_bundle/Contents/Resources/Shaders"
cp "$no_shader_app/Contents/Resources/ru.lproj/Localizable.strings" "$no_shader_bundle/Contents/Resources/ru.lproj/Localizable.strings"

# The host target uses SWIFT_VERSION=5.0. Compile its actual sources in the same
# language mode, using the current Xcode toolchain and no production test seams.
xcrun swiftc -swift-version 5 -module-cache-path "$no_shader_workspace/ModuleCache" \
    -F "$no_shader_compile_frameworks" \
    "$no_shader_repo/OpenEmu/OEShadersModel+OpenEmu.swift" \
    "$no_shader_repo/OpenEmu/ShaderControl.swift" \
    "$no_shader_tests/NoShaderSelectionSmokeTests.swift" \
    -framework AppKit -framework OpenEmuBase -framework OpenEmuSystem \
    -framework OpenEmuKit -framework OpenEmuShaders \
    -Xlinker -rpath -Xlinker "$no_shader_frameworks" \
    -o "$no_shader_bundle/Contents/MacOS/no-shader-selection-tests"

for no_shader_mode in exercise restart; do
    "$no_shader_bundle/Contents/MacOS/no-shader-selection-tests" \
        "$no_shader_workspace/profile" "$no_shader_mode" -AppleLanguages '(ru)'
done
echo "Test-only files retained at $no_shader_workspace"
