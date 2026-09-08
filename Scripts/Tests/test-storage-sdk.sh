#!/usr/bin/env bash
# Compile and exercise the storage SDK without launching OpenEmu or changing
# the user's profile. Run from any directory; DEVELOPER_DIR selects Xcode.
set -euo pipefail

storage_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
storage_sdk_directory="$(cd "$storage_tests_directory/../../OpenEmu-SDK/OpenEmuBase" && pwd)"
storage_test_workspace="$(mktemp -d /private/tmp/openemu-storage-sdk-tests.XXXXXX)"

cleanup_storage_tests() {
    # Only remove the private, uniquely-created workspace owned by this run.
    case "$storage_test_workspace" in
        /private/tmp/openemu-storage-sdk-tests.*)
            rm -rf -- "$storage_test_workspace"
            ;;
    esac
}
trap cleanup_storage_tests EXIT

if [[ "$(id -u)" == 0 ]]; then
    echo "Run these permission tests as a normal user, not root." >&2
    exit 1
fi

storage_clang_flags=(
    -fobjc-arc -fmodules
    "-fmodules-cache-path=$storage_test_workspace/ClangModuleCache"
    -Wall -Wextra -Werror -mmacosx-version-min=11.0
    -framework Foundation -I "$storage_sdk_directory"
)
storage_swift_flags=(
    -typecheck -swift-version 6 -strict-concurrency=complete
    -module-cache-path "$storage_test_workspace/SwiftModuleCache"
)

xcrun clang "${storage_clang_flags[@]}" \
    "$storage_sdk_directory/OEStoragePaths.m" "$storage_tests_directory/StoragePathsSmokeTests.m" \
    -o "$storage_test_workspace/storage-paths-tests"
xcrun clang "${storage_clang_flags[@]}" \
    "$storage_sdk_directory/OEPreferences.m" "$storage_tests_directory/PreferencesSmokeTests.m" \
    -o "$storage_test_workspace/preferences-tests"

mkdir "$storage_test_workspace/paths"
"$storage_test_workspace/storage-paths-tests" "$storage_test_workspace/paths"
for storage_preferences_mode in writer readonly invalid batch; do
    mkdir "$storage_test_workspace/$storage_preferences_mode"
    "$storage_test_workspace/preferences-tests" "$storage_preferences_mode" "$storage_test_workspace/$storage_preferences_mode"
done
"$storage_test_workspace/preferences-tests" reopen "$storage_test_workspace/writer.disconnected"
mkdir "$storage_test_workspace/arguments"
"$storage_test_workspace/preferences-tests" arguments "$storage_test_workspace/arguments" \
    -setupAssistantFinished YES -argumentWins from-command-line -argumentOnly transient
"$storage_test_workspace/preferences-tests" arguments-saved "$storage_test_workspace/arguments"

xcrun swiftc "${storage_swift_flags[@]}" \
    -import-objc-header "$storage_sdk_directory/OEStoragePaths.h" \
    "$storage_tests_directory/StoragePathsImportTests.swift"
xcrun swiftc "${storage_swift_flags[@]}" \
    -import-objc-header "$storage_sdk_directory/OEPreferences.h" \
    "$storage_tests_directory/PreferencesImportTests.swift"

echo "PASS: storage SDK runtime tests and Swift 6 imports"
