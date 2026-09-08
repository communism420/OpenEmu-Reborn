#!/usr/bin/env bash
# Deterministically exercise the actual SDK's lock-acquisition race guard.
# The test-only flock shim touches only this retained mktemp fixture.
set -euo pipefail

lock_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lock_test_workspace="$(mktemp -d /private/tmp/openemu-lock-acquire-tests.XXXXXX)"
echo "Retained lock-acquisition fixture: $lock_test_workspace"

xcrun clang -fobjc-arc -fmodules \
    "-fmodules-cache-path=$lock_test_workspace/ModuleCache" \
    -Wall -Wextra -Werror -mmacosx-version-min=11.0 \
    "$lock_tests_directory/PreferencesLockAcquireSmokeTests.m" \
    -framework Foundation -o "$lock_test_workspace/lock-acquire-tests"

"$lock_test_workspace/lock-acquire-tests" "$lock_test_workspace"
