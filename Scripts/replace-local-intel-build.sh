#!/usr/bin/env bash
# Copyright (c) 2026, OpenEmu Team
# SPDX-License-Identifier: BSD-2-Clause
# Publish one local user-facing package. No app or core build is performed.
set -euo pipefail

local_publish_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
local_publish_repo="$(dirname "$local_publish_scripts")"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo "Usage: $0 --signing-identity <40-hex SHA-1> [--cores /absolute/already-built/cores]"
  echo "Updates ONLY $local_publish_repo/OpenEmu-Intel-test. Quit OpenEmu first."
  echo "Uses cores from that existing package unless --cores is supplied for initial publication."
  echo "After verified publication, DELETES the previous package and consumes ONLY:"
  echo "$local_publish_repo/tmp/agent/data-folder-derived/Build/Products/Release/OpenEmu.app"
  echo "Object caches, other build products, signing keys and game data are not removed."
  exit 0
fi

mkdir -p "$local_publish_repo/tmp/agent/local-publication-module-cache"
local_publish_tools="$(mktemp -d "$local_publish_repo/tmp/agent/.publish-tools.XXXXXX")"
cleanup_local_publish_tools() {
  # Only these two generated executables, followed by an empty-directory removal.
  for local_publish_name in publisher registry; do
    if [[ -f "$local_publish_tools/$local_publish_name" && ! -L "$local_publish_tools/$local_publish_name" ]]; then
      unlink "$local_publish_tools/$local_publish_name"
    fi
  done
  rmdir "$local_publish_tools" 2>/dev/null || true
}
trap cleanup_local_publish_tools EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "$local_publish_repo/tmp/agent/local-publication-module-cache" \
  "$local_publish_scripts/LocalBuildPublisher.swift" -o "$local_publish_tools/publisher"
xcrun swiftc -swift-version 6 \
  -module-cache-path "$local_publish_repo/tmp/agent/local-publication-module-cache" \
  "$local_publish_scripts/LocalBuildRegistry.swift" -o "$local_publish_tools/registry"
"$local_publish_tools/publisher" "$local_publish_tools/registry" "$@"
