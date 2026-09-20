#!/usr/bin/env bash
# Run actual update-check methods with an in-memory HTTPS transport. No request
# can leave the fixture; no core, user preference, application or key is changed.
set -euo pipefail
core_check_tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core_check_repo="$(cd "$core_check_tests/../.." && pwd)"
core_check_frameworks="${1:-$core_check_repo/tmp/agent/data-folder-derived/Build/Products/Release}"
if [[ $# -gt 1 || ! -f "$core_check_frameworks/Sparkle.framework/Modules/module.modulemap" ]]; then
    echo "Usage: bash $0 /absolute/path/to/already-built-frameworks" >&2
    exit 2
fi
core_check_frameworks="$(cd "$core_check_frameworks" && pwd)"
core_check_workspace="$(mktemp -d /private/tmp/openemu-core-update-checks.XXXXXX)"
trap 'echo "Test-only artifacts retained at: $core_check_workspace"' EXIT
core_check_bundle="$core_check_workspace/CoreUpdateCheckTests.bundle"
mkdir -p "$core_check_bundle/Contents/MacOS"
core_check_plist="$core_check_bundle/Contents/Info.plist"
plutil -create xml1 "$core_check_plist"
plutil -insert CFBundleIdentifier -string org.openemu.tests.CoreUpdateChecks "$core_check_plist"
plutil -insert CFBundleExecutable -string core-update-checks "$core_check_plist"
plutil -insert CFBundlePackageType -string BNDL "$core_check_plist"
plutil -insert SUPublicEDKey -string AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= "$core_check_plist"
plutil -insert OECoreUpdateCatalogs -json '{"arm64":"https://updates.example.test/arm64/catalog.xml","x86_64":"https://updates.example.test/x86_64/catalog.xml"}' "$core_check_plist"

# Keep production callback/cancellation/grouping bodies unchanged; replace only
# unrelated UI/download collaborators and private access in the fixture driver.
awk '
    BEGIN { print "import Foundation\nimport OSLog\nimport Sparkle.SUStandardVersionComparator\nextension CoreUpdater {" }
    /^    @objc func checkForUpdates\(/ { methods = 1; started = 1 }
    methods && /^    \/\/ MARK: - Installing/ { methods = 0; ended = 1; print "}" }
    methods { sub(/private func/, "func"); print }
    /^private final class CoreAppcast/ { appcast = 1; appcastStarted = 1 }
    appcast { sub(/^private final class/, "final class"); print }
    END { if (!started || !ended || !appcastStarted) exit 1 }
' "$core_check_repo/OpenEmu/CoreUpdater.swift" > "$core_check_workspace/CheckMethods.swift"

xcrun swiftc -swift-version 5 -module-cache-path "$core_check_workspace/ModuleCache" \
    -F "$core_check_frameworks" "$core_check_repo/OpenEmu/OECoreUpdateSecurity.swift" \
    "$core_check_workspace/CheckMethods.swift" "$core_check_tests/CoreUpdateCheckSmokeTests.swift" \
    -framework Foundation -framework CryptoKit -framework Sparkle \
    -Xlinker -rpath -Xlinker "$core_check_frameworks" \
    -o "$core_check_bundle/Contents/MacOS/core-update-checks"
env -u OE_DISABLE_UPDATE_CHECK "$core_check_bundle/Contents/MacOS/core-update-checks"
