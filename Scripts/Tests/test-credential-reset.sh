#!/usr/bin/env bash
# Compile only the credential store and an isolated test harness; no app or cores.
set -euo pipefail

credential_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
credential_repository="$(cd "$credential_tests_directory/../.." && pwd)"
credential_test_workspace="$(mktemp -d /private/tmp/openemu-credential-tests.XXXXXX)"
cleanup_credential_tests() {
    case "$credential_test_workspace" in
        /private/tmp/openemu-credential-tests.*) rm -rf -- "$credential_test_workspace" ;;
    esac
}
trap cleanup_credential_tests EXIT

xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -module-cache-path "$credential_test_workspace/SwiftModuleCache" \
    "$credential_repository/OpenEmu/OECredentialStore.swift" \
    "$credential_tests_directory/CredentialResetSmokeTests.swift" \
    -framework Foundation -framework CryptoKit -framework IOKit -framework Security \
    -o "$credential_test_workspace/credential-reset-tests"

mkdir "$credential_test_workspace/loaded" "$credential_test_workspace/fresh"
for credential_test_mode in loaded fresh; do
    "$credential_test_workspace/credential-reset-tests" \
        "$credential_test_workspace/$credential_test_mode" "$credential_test_mode"
    "$credential_test_workspace/credential-reset-tests" \
        "$credential_test_workspace/$credential_test_mode" restart
done
