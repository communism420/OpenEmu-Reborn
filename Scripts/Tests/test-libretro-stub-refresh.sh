#!/usr/bin/env bash
# Exact production refresh helper + private files and tiny synthetic Mach-O stubs.
# Does not build/install emulator cores, launch OpenEmu, touch user data or keys.
set -euo pipefail

refresh_tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
refresh_repo="$(cd "$refresh_tests/../.." && pwd)"
if [[ $# -ne 0 ]]; then
    echo "Usage: bash $0" >&2
    exit 2
fi
refresh_workspace="$(mktemp -d /private/tmp/openemu-libretro-refresh-XXXXXX)"
trap 'echo "Private wrapper refresh fixtures retained at: $refresh_workspace"' EXIT

for refresh_variant in old new; do
    refresh_definitions=(-D REFRESH_BRIDGE_FIXTURE)
    if [[ "$refresh_variant" == new ]]; then
        refresh_definitions+=(-D REFRESH_BRIDGE_NEW)
    fi
    xcrun swiftc -swift-version 6 -strict-concurrency=complete \
        -module-cache-path "$refresh_workspace/ModuleCache" \
        -emit-library "${refresh_definitions[@]}" \
        "$refresh_tests/LibretroStubRefreshSmokeTests.swift" \
        -o "$refresh_workspace/$refresh_variant-fixture.dylib"
done

xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -module-cache-path "$refresh_workspace/ModuleCache" \
    "$refresh_repo/OpenEmu/OELibretroStubRefresh.swift" \
    "$refresh_tests/LibretroStubRefreshSmokeTests.swift" \
    -o "$refresh_workspace/stub-refresh-tests"

mkdir "$refresh_workspace/fixtures" "$refresh_workspace/PrivateHome"
env CFFIXED_USER_HOME="$refresh_workspace/PrivateHome" \
    "$refresh_workspace/stub-refresh-tests" "$refresh_workspace/fixtures" \
    "$refresh_workspace/old-fixture.dylib" "$refresh_workspace/new-fixture.dylib"
