#!/usr/bin/env bash
# Copyright (c) 2026, OpenEmu Team
# SPDX-License-Identifier: BSD-2-Clause
# Test-only command stand-in. It cannot read a Keychain or sign any bundle.
set -euo pipefail

case "${OE_PACKAGE_TEST_ROOT:-}" in
  /private/tmp/openemu-package-signing-tests.*) ;;
  *) echo "invalid private package test root" >&2; exit 98 ;;
esac
command_name="${0##*/}"
printf '%s\n' "$command_name" >> "$OE_PACKAGE_TEST_ROOT/commands.log"
if [[ "$command_name" != security || "$*" != 'find-identity -v -p codesigning' ]]; then
  echo "unexpected command: fixture never signs or packages code" >&2
  exit 99
fi
if [[ "${OE_PACKAGE_TEST_SECURITY_FAIL:-NO}" == YES ]]; then exit 7; fi
printf '  1) %s "Synthetic code-signing fixture"\n' "${OE_PACKAGE_TEST_REPORTED_IDENTITY:-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB}"
# The requested hash appearing in a name must not be accepted as the identity.
printf '  2) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC "%s"\n' "${OE_PACKAGE_TEST_NAME_ONLY_IDENTITY:-unrelated}"
printf '     2 valid identities found\n'
