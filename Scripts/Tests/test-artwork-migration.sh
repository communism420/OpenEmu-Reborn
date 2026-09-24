#!/usr/bin/env bash
# Compile the actual artwork model against an in-memory private database.
# Does not build cores, launch OpenEmu or read/write the user's library.
set -euo pipefail
artwork_tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
artwork_repo="$(cd "$artwork_tests/../.." && pwd)"
if [[ $# -ne 0 ]]; then
    echo "Usage: bash $0" >&2
    exit 2
fi
artwork_workspace="$(mktemp -d /private/tmp/openemu-artwork-migration-XXXXXX)"
trap 'echo "Private artwork fixtures retained at: $artwork_workspace"' EXIT
mkdir "$artwork_workspace/fixtures" "$artwork_workspace/PrivateHome"
xcrun swiftc -swift-version 5 \
    -module-cache-path "$artwork_workspace/ModuleCache" \
    "$artwork_repo/OpenEmu/OEDBImage.swift" \
    "$artwork_tests/ArtworkMigrationSmokeTests.swift" \
    -o "$artwork_workspace/artwork-migration-tests"
env CFFIXED_USER_HOME="$artwork_workspace/PrivateHome" \
    "$artwork_workspace/artwork-migration-tests" "$artwork_workspace/fixtures"
