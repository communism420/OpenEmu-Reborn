#!/usr/bin/env bash
# Copyright (c) 2026, OpenEmu Team
# SPDX-License-Identifier: BSD-3-Clause
# Read-only checks of two already-built, already-signed Intel host versions.
# No signing, Keychain/trust changes, app launches, builds or temporary files.
set -euo pipefail

usage() {
  echo "Usage: bash $0 <app-A> <app-B> <40-hex certificate SHA-1> <original-cores-directory>"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

if [ "$#" -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
  usage
  exit 0
fi
[ "$#" -eq 4 ] || { usage >&2; exit 1; }
[[ "$3" =~ ^[0-9A-Fa-f]{40}$ ]] || fail "certificate identity must be an exact 40-hex SHA-1 fingerprint"
stable_identity=$(printf '%s' "$3" | tr '[:lower:]' '[:upper:]')

for stable_command in codesign xcrun diff awk; do
  command -v "$stable_command" >/dev/null || fail "required command is unavailable: $stable_command"
done

for stable_input_app in "$1" "$2"; do
  [ -d "$stable_input_app" ] && [ -f "$stable_input_app/Contents/MacOS/OpenEmu" ] ||
    fail "OpenEmu host executable is missing: $stable_input_app"
done
[ -d "$4" ] || fail "original core directory is missing: $4"
# Absolute paths also prevent codesign from mistaking a numeric path for a PID.
stable_app_a=$(cd -- "$1" && pwd -P)
stable_app_b=$(cd -- "$2" && pwd -P)
stable_original_cores=$(cd -- "$4" && pwd -P)

host_uuid() {
  local uuid_output
  uuid_output=$(xcrun dwarfdump --uuid "$1/Contents/MacOS/OpenEmu") || return 1
  printf '%s\n' "$uuid_output" | awk '
    $1 == "UUID:" && $3 == "(x86_64)" { print toupper($2); count++ }
    END { exit count != 1 }
  '
}

stable_uuid_a=$(host_uuid "$stable_app_a") || fail "app A must have exactly one x86_64 host LC_UUID"
stable_uuid_b=$(host_uuid "$stable_app_b") || fail "app B must have exactly one x86_64 host LC_UUID"
for stable_uuid in "$stable_uuid_a" "$stable_uuid_b"; do
  [[ "$stable_uuid" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]] ||
    fail "dwarfdump returned an invalid x86_64 UUID"
done
[ "$stable_uuid_a" != "$stable_uuid_b" ] || fail "the two hosts have the same LC_UUID; different host builds are required"
printf 'PASS: different x86_64 host builds (A=%s; B=%s)\n' "$stable_uuid_a" "$stable_uuid_b"

run_check() {
  local description="$1"
  local check_output
  shift
  if ! check_output=$("$@" 2>&1); then
    printf '%s\n' "$check_output" >&2
    fail "$description"
  fi
  echo "PASS: $description"
}

# Integrity applies recursively. The certificate predicate below applies only
# to the host: nested cores intentionally retain their original signatures.
run_check "app A deep/strict signature integrity" codesign --verify --deep --strict "$stable_app_a"
run_check "app B deep/strict signature integrity" codesign --verify --deep --strict "$stable_app_b"
stable_leaf_requirement="=certificate leaf = H\"$stable_identity\""
run_check "app A expected leaf certificate" codesign --verify --strict --test-requirement "$stable_leaf_requirement" "$stable_app_a"
run_check "app B expected leaf certificate" codesign --verify --strict --test-requirement "$stable_leaf_requirement" "$stable_app_b"

designated_requirement() {
  local requirement_output
  requirement_output=$(codesign --display --architecture x86_64 --requirements - "$1" 2>&1) || return 1
  # Implied requirements have a '# ' prefix. -R needs the predicate alone,
  # without the requirement-set prefix 'designated =>'. Require one result.
  printf '%s\n' "$requirement_output" | awk '
    /^#?[[:space:]]*designated => / {
      sub(/^#?[[:space:]]*designated => /, "")
      if (length == 0) invalid = 1
      print
      count++
    }
    END { exit count != 1 || invalid }
  '
}

stable_dr_a=$(designated_requirement "$stable_app_a") || fail "cannot read app A designated requirement"
stable_dr_b=$(designated_requirement "$stable_app_b") || fail "cannot read app B designated requirement"
if printf '%s\n%s\n' "$stable_dr_a" "$stable_dr_b" | awk '
  /(^|[^[:alnum:]_])cdhash([^[:alnum:]_]|$)/ { found = 1 }
  END { exit !found }
'; then
  fail "a designated requirement still depends on one code hash"
fi
[ "$stable_dr_a" = "$stable_dr_b" ] || fail "the designated requirements differ between host builds"
echo "PASS: identical designated requirements without cdhash"
# The leading '=' means literal requirement text, not a filename.
run_check "app B satisfies app A identity" codesign --verify --strict --test-requirement "=$stable_dr_a" "$stable_app_b"
run_check "app A satisfies app B identity" codesign --verify --strict --test-requirement "=$stable_dr_b" "$stable_app_a"

check_core_count() {
  local core_directory="$1"
  local core_plugin
  local core_plugins
  [ -d "$core_directory" ] && [ ! -L "$core_directory" ] || fail "core directory is missing or is a symlink: $core_directory"
  shopt -s nullglob
  core_plugins=("$core_directory"/*.oecoreplugin)
  shopt -u nullglob
  [ "${#core_plugins[@]}" -eq 28 ] || fail "expected 28 core bundles: $core_directory"
  for core_plugin in "${core_plugins[@]}"; do
    [ -d "$core_plugin" ] && [ ! -L "$core_plugin" ] || fail "core bundle is missing or is a symlink: $core_plugin"
  done
}

check_core_count "$stable_original_cores"
check_core_count "$stable_app_a/Contents/PlugIns/Cores"
check_core_count "$stable_app_b/Contents/PlugIns/Cores"
run_check "app A: all 28 core bundles unchanged, including symbolic links" \
  diff -qr --no-dereference "$stable_original_cores" "$stable_app_a/Contents/PlugIns/Cores"
run_check "app B: all 28 core bundles unchanged, including symbolic links" \
  diff -qr --no-dereference "$stable_original_cores" "$stable_app_b/Contents/PlugIns/Cores"
echo "PASS: stable host signing and unchanged bundled cores. This does not test gameplay or grant macOS permissions."
