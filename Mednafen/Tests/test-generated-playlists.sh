#!/usr/bin/env bash
# Standalone Foundation tests. No OpenEmu/core launch or user-library writes.
set -euo pipefail

playlist_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
playlist_repository="$(cd "$playlist_tests_directory/../.." && pwd)"
playlist_test_workspace="$(mktemp -d /private/tmp/openemu-playlist-tests.XXXXXX)"
cleanup_playlist_tests() {
    case "$playlist_test_workspace" in
        /private/tmp/openemu-playlist-tests.*) rm -rf -- "$playlist_test_workspace" ;;
    esac
}
trap cleanup_playlist_tests EXIT

if [[ "$(id -u)" == 0 ]]; then
    echo "Run permission tests as a normal user, not root." >&2
    exit 1
fi

xcrun clang -fobjc-arc -fmodules \
    "-fmodules-cache-path=$playlist_test_workspace/ModuleCache" \
    -Wall -Wextra -Werror -mmacosx-version-min=11.0 -framework Foundation \
    -I "$playlist_repository/Mednafen" -I "$playlist_repository/OpenEmu-SDK" \
    "$playlist_repository/OpenEmu-SDK/OpenEmuBase/OEStoragePaths.m" \
    "$playlist_tests_directory/GeneratedPlaylistTests.m" \
    -o "$playlist_test_workspace/generated-playlist-tests"
mkdir "$playlist_test_workspace/fixtures"
"$playlist_test_workspace/generated-playlist-tests" "$playlist_test_workspace/fixtures"
