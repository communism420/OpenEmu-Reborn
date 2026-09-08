#!/usr/bin/env bash
# Actual removal engine with fixture-only Trash injection. No app/core builds.
set -euo pipefail

removal_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
removal_repository="$(cd "$removal_tests_directory/../.." && pwd)"
removal_test_workspace="$(mktemp -d /private/tmp/openemu-removal-tests.XXXXXX)"
cleanup_removal_tests() {
    case "$removal_test_workspace" in
        /private/tmp/openemu-removal-tests.*) rm -rf -- "$removal_test_workspace" ;;
    esac
}
trap cleanup_removal_tests EXIT

for removal_source in OEStoragePaths OEPreferences; do
    xcrun clang -c -fobjc-arc -fmodules \
        "-fmodules-cache-path=$removal_test_workspace/ClangModuleCache" \
        -Wall -Wextra -Werror -mmacosx-version-min=11.0 \
        "$removal_repository/OpenEmu-SDK/OpenEmuBase/$removal_source.m" \
        -o "$removal_test_workspace/$removal_source.o"
done

xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "$removal_test_workspace/SwiftModuleCache" \
    -I "$removal_tests_directory" \
    "$removal_repository/OpenEmu/OEDataFolderSetup.swift" \
    "$removal_repository/OpenEmu/OEDataRemoval.swift" \
    "$removal_tests_directory/DataRemovalSmokeTests.swift" \
    "$removal_test_workspace/OEStoragePaths.o" "$removal_test_workspace/OEPreferences.o" \
    -framework Foundation -framework AppKit -o "$removal_test_workspace/data-removal-tests"

mkdir "$removal_test_workspace/fixtures"
"$removal_test_workspace/data-removal-tests" "$removal_test_workspace/fixtures"
