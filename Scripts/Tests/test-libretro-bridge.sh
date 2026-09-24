#!/usr/bin/env bash
# Build only a tiny synthetic fixture, never an emulator core or application.
set -euo pipefail
bridge_tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bridge_repo="$(cd "$bridge_tests/../.." && pwd)"
bridge_frameworks="${1:-$bridge_repo/tmp/agent/data-folder-derived/Build/Products/Release}"
[[ $# -le 1 && -f "$bridge_frameworks/OpenEmuBase.framework/Versions/A/OpenEmuBase" ]] || {
    echo 'Pass the absolute directory containing the just-built OpenEmuBase.framework.' >&2
    exit 2
}
bridge_frameworks="$(cd "$bridge_frameworks" && pwd)"
bridge_fixture="$(mktemp -d /private/tmp/openemu-libretro-fixture.XXXXXX)"
trap 'echo "Synthetic bridge test artifacts: $bridge_fixture"' EXIT
xcrun clang -dynamiclib -Wall -Wextra -Werror \
    -I "$bridge_repo/OpenEmu-SDK/OpenEmuBase" \
    "$bridge_tests/LibretroFixture.c" -o "$bridge_fixture/fixture_libretro.dylib"
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror \
    "-fmodules-cache-path=$bridge_fixture/ModuleCache" \
    -I "$bridge_repo/OpenEmu-SDK/OpenEmuBase" -F "$bridge_frameworks" \
    "$bridge_tests/LibretroBridgeSmokeTests.m" -framework Foundation -framework OpenEmuBase \
    -Wl,-rpath,"$bridge_frameworks" -o "$bridge_fixture/bridge-tests"
mkdir "$bridge_fixture/PrivateHome"
env CFFIXED_USER_HOME="$bridge_fixture/PrivateHome" "$bridge_fixture/bridge-tests" "$bridge_fixture"
