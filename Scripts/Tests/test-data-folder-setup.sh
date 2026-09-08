#!/usr/bin/env bash
# Compile the actual first-launch implementation and test its non-UI helpers.
# No configureOrQuit call, app launch, real settings domain, or picker is used.
set -euo pipefail

data_folder_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
data_folder_repository="$(cd "$data_folder_tests_directory/../.." && pwd)"
data_folder_test_workspace="$(mktemp -d /private/tmp/openemu-data-folder-tests.XXXXXX)"
cleanup_data_folder_tests() {
    case "$data_folder_test_workspace" in
        /private/tmp/openemu-data-folder-tests.*) rm -rf -- "$data_folder_test_workspace" ;;
    esac
}
trap cleanup_data_folder_tests EXIT

for data_folder_source in OEStoragePaths OEPreferences; do
    xcrun clang -c -fobjc-arc -fmodules \
        "-fmodules-cache-path=$data_folder_test_workspace/ClangModuleCache" \
        -Wall -Wextra -Werror -mmacosx-version-min=11.0 \
        "$data_folder_repository/OpenEmu-SDK/OpenEmuBase/$data_folder_source.m" \
        -o "$data_folder_test_workspace/$data_folder_source.o"
done

xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -module-cache-path "$data_folder_test_workspace/SwiftModuleCache" \
    -I "$data_folder_tests_directory" \
    "$data_folder_repository/OpenEmu/OEDataFolderSetup.swift" \
    "$data_folder_tests_directory/DataFolderSetupSmokeTests.swift" \
    "$data_folder_test_workspace/OEStoragePaths.o" \
    "$data_folder_test_workspace/OEPreferences.o" \
    -framework Foundation -framework AppKit \
    -o "$data_folder_test_workspace/data-folder-tests"

mkdir "$data_folder_test_workspace/profile"
"$data_folder_test_workspace/data-folder-tests" "$data_folder_test_workspace/profile"
