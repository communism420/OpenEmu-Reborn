#!/usr/bin/env bash
# Compile the exact production authenticator; fixture keys exist only in memory.
# No network, real signing key, Keychain, extraction, core or app build is used.
set -euo pipefail

core_security_tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core_security_repo="$(cd "$core_security_tests/../.." && pwd)"
core_security_frameworks="${1:-$core_security_repo/tmp/agent/data-folder-derived/Build/Products/Release}"
if [[ $# -gt 1 || ! -f "$core_security_frameworks/Sparkle.framework/Modules/module.modulemap" ]]; then
    echo "Usage: bash $0 /absolute/path/to/already-built-frameworks" >&2
    exit 2
fi
core_security_frameworks="$(cd "$core_security_frameworks" && pwd)"
core_security_workspace="$(mktemp -d /private/tmp/openemu-core-update-security.XXXXXX)"
trap 'echo "Test-only artifacts retained at: $core_security_workspace"' EXIT

xcrun swiftc -swift-version 5 -module-cache-path "$core_security_workspace/ModuleCache" \
    -F "$core_security_frameworks" \
    "$core_security_repo/OpenEmu/OECoreUpdateSecurity.swift" \
    "$core_security_tests/CoreUpdateSecuritySmokeTests.swift" \
    -framework Foundation -framework CryptoKit -framework Sparkle \
    -Xlinker -rpath -Xlinker "$core_security_frameworks" \
    -o "$core_security_workspace/core-update-security-tests"

"$core_security_workspace/core-update-security-tests" "$core_security_workspace"
