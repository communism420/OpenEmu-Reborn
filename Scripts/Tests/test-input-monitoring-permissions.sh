#!/usr/bin/env bash
# Compile the actual, bounded AppDelegate permission-method block against
# in-memory collaborators. No host/core build, app launch or real TCC call.
set -euo pipefail

permission_tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
permission_repository="$(cd "$permission_tests/../.." && pwd)"
permission_workspace="$(mktemp -d /private/tmp/openemu-input-permission-tests.XXXXXX)"
trap 'echo "Permission test artifacts retained at: $permission_workspace"' EXIT

# Mechanical extraction preserves production method bodies. Only fileprivate
# visibility changes so the separate test file can invoke the methods directly;
# the @objc Check Again target/action remains intact for dispatch through mocks.
awk '
    BEGIN { print "import AppKit\n@MainActor extension PermissionTestDelegate {" }
    /^    fileprivate func setUpHIDSupport\(\)/ { copying = 1; started = 1 }
    copying && /^    \/\/\/ Clears a stale/ { copying = 0; ended = 1 }
    copying && /^    @objc fileprivate func recheckInputMonitoringPermission\(/ { recheckStarted = 1 }
    copying { sub(/fileprivate func/, "func"); print }
    /^    func applicationDidBecomeActive\(_ notification: Notification\)/ { activation = 1; activationStarted = 1 }
    activation { print; if (/^    }/) { activation = 0; activationEnded = 1 } }
    END { print "}"; if (!started || !ended || !recheckStarted || !activationStarted || !activationEnded) exit 1 }
' "$permission_repository/OpenEmu/AppDelegate.swift" > "$permission_workspace/PermissionMethods.swift"

for permission_configuration in Release Debug; do
    permission_flags=(-parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors
                      -target "$(uname -m)-apple-macos11.0")
    if [[ "$permission_configuration" == Debug ]]; then permission_flags+=(-D DEBUG); fi
    xcrun swiftc "${permission_flags[@]}" -module-cache-path "$permission_workspace/ModuleCache" \
        "$permission_workspace/PermissionMethods.swift" \
        "$permission_tests/InputMonitoringPermissionSmokeTests.swift" \
        -framework AppKit -o "$permission_workspace/permission-tests-$permission_configuration"
    "$permission_workspace/permission-tests-$permission_configuration" \
        2>&1 | tee "$permission_workspace/$permission_configuration.log"
done
