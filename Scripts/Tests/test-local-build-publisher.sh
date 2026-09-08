#!/usr/bin/env bash
# Copyright (c) 2026, OpenEmu Team
# SPDX-License-Identifier: BSD-2-Clause
# Only private fixtures and injected operations; no app/core builds or real signing.
set -euo pipefail
publisher_test_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
publisher_test_repository="$(cd "$publisher_test_scripts/../.." && pwd -P)"
publisher_test_workspace="$(mktemp -d /private/tmp/openemu-local-publisher-tests.XXXXXX)"
echo "Retained private publisher fixtures: $publisher_test_workspace"
xcrun swiftc -swift-version 6 -parse-as-library -D LOCAL_PUBLISHER_TESTS \
  -module-cache-path "$publisher_test_workspace/ModuleCache" \
  "$publisher_test_repository/Scripts/LocalBuildPublisher.swift" \
  "$publisher_test_scripts/LocalBuildPublisherSmokeTests.swift" \
  -o "$publisher_test_workspace/publisher-tests"
"$publisher_test_workspace/publisher-tests" "$publisher_test_workspace" 2>&1 | tee "$publisher_test_workspace/tests.log"
