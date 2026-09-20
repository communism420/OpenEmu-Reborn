#!/usr/bin/env bash
# Exercise production install/rollback methods with metadata-only fake cores.
# Uses an existing OpenEmuKit build; never builds, loads or installs a real core.
set -euo pipefail

core_install_tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core_install_repo="$(cd "$core_install_tests/../.." && pwd)"
core_install_frameworks="${1:-$core_install_repo/tmp/agent/data-folder-derived/Build/Products/Release}"
if [[ $# -gt 1 || ! -d "$core_install_frameworks/OpenEmuKit.framework/Modules/OpenEmuKit.swiftmodule" ]]; then
    echo "Usage: bash $0 /absolute/path/to/already-built-frameworks" >&2
    exit 2
fi
core_install_frameworks="$(cd "$core_install_frameworks" && pwd)"
core_install_workspace="$(mktemp -d /private/tmp/openemu-core-update-install.XXXXXX)"
trap 'echo "Test-only artifacts retained at: $core_install_workspace"' EXIT

# Compile exact production method bodies. This deliberately excludes network,
# signature and archive processing: those have independent security tests.
# Only private visibility is relaxed to let the metadata fixture call them.
awk '
    BEGIN { print "import Foundation\nimport OpenEmuKit\nextension CoreDownload {" }
    /^    struct InstallationTransaction/ { structures = 1; structureStart = 1 }
    /^    static var runningArchitecture/ { structures = 0; structureEnd = 1 }
    structures { print }
    /^    func install\(/ { methods = 1; methodStart = 1 }
    /^    func reportSuccess\(/ { methods = 0; methodEnd = 1 }
    methods { print }
    /^private enum CoreDownloadError:/ { print "}"; errors = 1; errorStart = 1 }
    errors && /^@objc protocol CoreDownloadDelegate:/ { errors = 0; errorEnd = 1 }
    errors { sub(/^private enum/, "enum"); print }
    END { if (!structureStart || !structureEnd || !methodStart || !methodEnd || !errorStart || !errorEnd) exit 1 }
' "$core_install_repo/OpenEmu/CoreDownload.swift" > "$core_install_workspace/InstallationMethods.swift"

xcrun swiftc -swift-version 5 -module-cache-path "$core_install_workspace/ModuleCache" \
    -F "$core_install_frameworks" \
    "$core_install_workspace/InstallationMethods.swift" \
    "$core_install_tests/CoreUpdateInstallationSmokeTests.swift" \
    -framework Foundation -framework OpenEmuKit \
    -Xlinker -rpath -Xlinker "$core_install_frameworks" \
    -o "$core_install_workspace/core-update-installation-tests"

"$core_install_workspace/core-update-installation-tests" "$core_install_workspace/fixtures" exercise
"$core_install_workspace/core-update-installation-tests" "$core_install_workspace/fixtures" restart
