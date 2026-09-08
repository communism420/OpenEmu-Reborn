#!/usr/bin/env bash
# Compile the actual worker with private transport-only collaborators. The
# deletion engine is a test double: these tests never invoke native Trash.
set -euo pipefail

removal_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
removal_repository="$(cd "$removal_tests_directory/../.." && pwd)"
removal_test_workspace="$(mktemp -d /private/tmp/openemu-removal-worker-tests.XXXXXX)"
echo "Worker transport fixtures: $removal_test_workspace"

xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "$removal_test_workspace/SwiftModuleCache" \
    "$removal_repository/OpenEmu/OEDataRemovalWorker.swift" \
    "$removal_tests_directory/DataRemovalWorkerSmokeTests.swift" \
    -framework AppKit -framework CryptoKit \
    -o "$removal_test_workspace/removal-worker-tests"

"$removal_test_workspace/removal-worker-tests" "$removal_test_workspace"
