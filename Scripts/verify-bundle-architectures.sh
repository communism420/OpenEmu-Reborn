#!/usr/bin/env bash
# Verify that every Mach-O binary and static archive in a bundle contains an
# expected CPU slice. This catches an incompatible embedded core or framework
# before an app/core artifact is distributed.

set -uo pipefail

TARGET_ARCH="${OPENEMU_ARCH:-$(uname -m)}"
BUNDLE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --arch)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: --arch requires arm64 or x86_64" >&2; exit 2; }
      TARGET_ARCH="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--arch arm64|x86_64] <bundle>"
      exit 0 ;;
    -*) echo "error: unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -n "$BUNDLE" ]; then
        echo "error: unexpected argument: $1" >&2
        exit 2
      fi
      BUNDLE="$1"
      shift ;;
  esac
done

case "$TARGET_ARCH" in
  arm64|x86_64) ;;
  *) echo "error: unsupported architecture '$TARGET_ARCH'" >&2; exit 2 ;;
esac

if [ -z "$BUNDLE" ] || [ ! -d "$BUNDLE" ]; then
  echo "error: bundle not found: ${BUNDLE:-<missing>}" >&2
  exit 2
fi

FAILURES_FILE=$(mktemp -t openemu_arch_failures.XXXXXX)
CHECKED_FILE=$(mktemp -t openemu_arch_checked.XXXXXX)
trap 'rm -f "$FAILURES_FILE" "$CHECKED_FILE"' EXIT
CHECKED=0

# The loop runs in a subshell on macOS bash 3.x, so failures are recorded in a
# temporary file instead of relying on a variable modified inside the loop.
find "$BUNDLE" -type f -print0 | while IFS= read -r -d '' candidate; do
  if lipo -archs "$candidate" >/dev/null 2>&1; then
    printf '1\n' >> "$CHECKED_FILE"
    if ! lipo "$candidate" -verify_arch "$TARGET_ARCH" >/dev/null 2>&1; then
      printf '%s\n' "$candidate" >> "$FAILURES_FILE"
    fi
    printf '.'
  fi
done
printf '\n'

CHECKED=$(wc -l < "$CHECKED_FILE" | tr -d ' ')

if [ "$CHECKED" -eq 0 ]; then
  echo "FAIL: no Mach-O binaries or static archives found in $BUNDLE" >&2
  exit 1
fi

if [ -s "$FAILURES_FILE" ]; then
  echo "FAIL: binaries missing $TARGET_ARCH in $BUNDLE:" >&2
  while IFS= read -r failed; do
    echo "  $failed ($(lipo -archs "$failed" 2>/dev/null || echo unknown))" >&2
  done < "$FAILURES_FILE"
  exit 1
fi

echo "PASS: $CHECKED Mach-O binaries/archives contain $TARGET_ARCH"
