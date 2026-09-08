#!/usr/bin/env bash
# Compile only an offscreen test executable against an ALREADY BUILT renderer.
# No app/core build, ROM, application launch or user profile is involved.
# Usage: bash Scripts/Tests/test-no-shader-rendering.sh [frameworks directory | OpenEmu.app] [build products for Swift modules]
set -euo pipefail

shader_test_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shader_repository="$(cd "$shader_test_directory/../.." && pwd)"
shader_default_products="$shader_repository/tmp/agent/data-folder-derived/Build/Products/Release"
shader_frameworks="${1:-$shader_default_products}"
shader_preset="$shader_repository/OpenEmu/Shaders/No Shader/No Shader.slangp"
if [[ "$shader_frameworks" == *.app ]]; then
    shader_preset="$shader_frameworks/Contents/Resources/Shaders/No Shader/No Shader.slangp"
    shader_frameworks="$shader_frameworks/Contents/Frameworks"
fi
if [[ ! -d "$shader_frameworks/OpenEmuShaders.framework" || ! -f "$shader_preset" ]]; then
    echo "An already-built OpenEmuShaders.framework and No Shader preset are required." >&2
    echo "Pass its frameworks directory, or a built OpenEmu.app containing No Shader." >&2
    exit 1
fi
shader_frameworks="$(cd "$shader_frameworks" && pwd)"
# Release packaging can remove compiler-only module files. Use existing build
# metadata to compile the test, while still linking/loading the packaged binary.
shader_modules="${2:-$shader_frameworks}"
if [[ ! -d "$shader_modules/OpenEmuShaders.framework/Modules/OpenEmuShaders.swiftmodule" && $# -lt 2 ]]; then
    shader_modules="$shader_default_products"
fi
if [[ ! -d "$shader_modules/OpenEmuShaders.framework/Modules/OpenEmuShaders.swiftmodule" ]]; then
    echo "Pass existing build products containing OpenEmuShaders.swiftmodule as the second argument." >&2
    exit 1
fi
shader_modules="$(cd "$shader_modules" && pwd)"
shader_workspace="$(mktemp -d /private/tmp/openemu-no-shader-rendering.XXXXXX)"
trap 'echo "Rendering test artifacts retained at: $shader_workspace"' EXIT
mkdir "$shader_workspace/Fixtures"
echo "Using existing renderer: $shader_frameworks/OpenEmuShaders.framework"
echo "Using existing Swift modules: $shader_modules/OpenEmuShaders.framework/Modules"

xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "$shader_workspace/SwiftModuleCache" \
    -F "$shader_frameworks" -F "$shader_modules" \
    -framework OpenEmuShaders -framework Metal -framework Foundation \
    -Xlinker -rpath -Xlinker "$shader_frameworks" \
    "$shader_test_directory/NoShaderRenderingSmokeTests.swift" \
    -o "$shader_workspace/no-shader-rendering-tests"

DYLD_FRAMEWORK_PATH="$shader_frameworks" \
    "$shader_workspace/no-shader-rendering-tests" "$shader_preset" "$shader_workspace/Fixtures" \
    2>&1 | tee "$shader_workspace/rendering.log"
