#!/usr/bin/env bash
# Copyright (c) 2026, OpenEmu Team
# SPDX-License-Identifier: BSD-2-Clause
# Argument/preflight regression only: no app/core build, real Keychain access,
# signature changes, bundle copies, trust changes or TCC calls.
set -euo pipefail

package_tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_repository="$(cd "$package_tests_directory/../.." && pwd)"
package_fixture="$(mktemp -d /private/tmp/openemu-package-signing-tests.XXXXXX)"
echo "Retained private signing preflight fixtures: $package_fixture"
mkdir "$package_fixture/bin"
for package_mock_command in security codesign ditto; do
  ln -s "$package_tests_directory/PackageSigningCommandMock.sh" "$package_fixture/bin/$package_mock_command"
done
package_identity=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
package_base_args=(--app "$package_fixture/Missing.app" --cores "$package_fixture/MissingCores" --output "$package_fixture/Output")

expect_failure() {
  local expected="$1"
  shift
  local output
  if output=$(env PATH="$package_fixture/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      OE_PACKAGE_TEST_ROOT="$package_fixture" \
      OE_PACKAGE_TEST_REPORTED_IDENTITY="${package_reported_identity:-$package_identity}" \
      OE_PACKAGE_TEST_NAME_ONLY_IDENTITY="${package_name_only_identity:-unrelated}" \
      OE_PACKAGE_TEST_SECURITY_FAIL="${package_security_fail:-NO}" \
      bash "$package_repository/Scripts/package-intel-test-build.sh" "${package_base_args[@]}" "$@" 2>&1); then
    echo "FAIL: invalid or missing package input unexpectedly succeeded" >&2
    exit 1
  fi
  if ! printf '%s\n' "$output" | grep -Fq -- "$expected"; then
    printf 'FAIL: expected %s; received %s\n' "$expected" "$output" >&2
    exit 1
  fi
  [[ ! -e "$package_fixture/Output" ]] || { echo "FAIL: preflight created staging output" >&2; exit 1; }
  echo "PASS: $expected"
}

expect_failure 'explicit --signing-identity or --ad-hoc-sign is required'
expect_failure 'requires a certificate SHA-1 fingerprint' --signing-identity
for package_invalid_identity in - 'OpenEmu Local Publisher' 0123 GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG; do
  expect_failure 'exact 40-hex certificate SHA-1 fingerprint' --signing-identity "$package_invalid_identity"
done
expect_failure 'choose exactly one signing mode' --ad-hoc-sign --signing-identity "$package_identity"
expect_failure 'choose exactly one signing mode' --signing-identity "$package_identity" --ad-hoc-sign
expect_failure 'choose exactly one signing mode' --ad-hoc-sign --ad-hoc-sign
expect_failure 'choose exactly one signing mode' --signing-identity "$package_identity" --signing-identity "$package_identity"
expect_failure 'OpenEmu.app is missing' --ad-hoc-sign
[[ ! -e "$package_fixture/commands.log" ]] || { echo 'FAIL: syntax/ad-hoc preflight accessed a signing command' >&2; exit 1; }

package_reported_identity=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
package_name_only_identity="$package_identity"
expect_failure 'requested valid code-signing identity is unavailable' --signing-identity "$package_identity"
package_reported_identity="$package_identity"
package_name_only_identity=unrelated
expect_failure 'OpenEmu.app is missing' --signing-identity aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
package_security_fail=YES
expect_failure 'could not inspect valid code-signing identities' --signing-identity "$package_identity"
[[ "$(wc -l < "$package_fixture/commands.log" | tr -d ' ')" == 3 ]] || { echo 'FAIL: unexpected number of identity lookups' >&2; exit 1; }
if grep -vqx security "$package_fixture/commands.log"; then
  echo 'FAIL: a preflight failure attempted to sign or package code' >&2
  exit 1
fi
echo 'PASS: explicit signing modes, exact identity matching, lowercase normalization and fail-closed preflight; no real signing or Keychain access'
