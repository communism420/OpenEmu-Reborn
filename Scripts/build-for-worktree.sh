#!/usr/bin/env bash
# build-for-worktree.sh — Build OpenEmu to a stable per-branch path so
# macOS privacy permissions persist across rebuilds of the same branch.
#
# Why: macOS binds permissions (Input Monitoring, Accessibility, etc.) to
# a specific app path + code signature. Xcode's default DerivedData uses a
# random hash per checkout — every fresh worktree = different path = lost
# permissions. This script forces a stable path: ~/Builds/openemu/<branch>/.
#
# Usage:
#   ./Scripts/build-for-worktree.sh                  # builds the OpenEmu scheme
#   ./Scripts/build-for-worktree.sh "OpenEmu + FCEU" # builds a specific scheme
#   ./Scripts/build-for-worktree.sh --arch x86_64    # builds for a specific CPU
#
# After building once, grant Input Monitoring (and any other permissions you
# need) to the printed app path in System Settings → Privacy & Security.
# Subsequent builds of the same branch land at the same path and inherit
# the granted permissions automatically.
#
# See docs/worktree-workflow.md for the full workflow and known caveats.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

WORKSPACE="OpenEmu-metal.xcworkspace"
SCHEME="OpenEmu"
TARGET_ARCH="${OPENEMU_ARCH:-$(uname -m)}"

while [ $# -gt 0 ]; do
  case "$1" in
    --arch)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: --arch requires arm64 or x86_64" >&2; exit 2; }
      TARGET_ARCH="$2"
      shift 2
      ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) echo "error: unknown flag: $1" >&2; exit 2 ;;
    *) SCHEME="$1"; shift ;;
  esac
done

case "$TARGET_ARCH" in
  arm64|x86_64) ;;
  *) echo "error: unsupported architecture '$TARGET_ARCH'" >&2; exit 2 ;;
esac

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|/|-|g')
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  echo "error: cannot determine branch name (detached HEAD or not a git repo)" >&2
  exit 1
fi

BUILD_DIR="$HOME/Builds/openemu/$BRANCH"
mkdir -p "$BUILD_DIR"

echo "Building scheme '$SCHEME' for branch '$BRANCH' ($TARGET_ARCH)"
echo "Output: $BUILD_DIR/Build/Products/Debug/"
echo ""

if ! xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "platform=macOS,arch=$TARGET_ARCH" \
  ARCHS="$TARGET_ARCH" \
  ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath "$BUILD_DIR" \
  build; then
  echo "error: xcodebuild failed; refusing to reuse or re-sign a stale app bundle" >&2
  exit 1
fi

# Auto-resolve a stable Apple Development signing identity if available.
# Falls back to ad-hoc (-) if no Developer cert is in the keychain.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
SIGN_ID="${SIGN_ID:--}"

APP_PATH="$BUILD_DIR/Build/Products/Debug/OpenEmu.app"
if [ -d "$APP_PATH" ]; then
  codesign --force --deep --sign "$SIGN_ID" "$APP_PATH" 2>/dev/null || true
  echo ""
  echo "===================="
  echo "Build complete."
  echo "App:    $APP_PATH"
  echo "Signed: $SIGN_ID"
  echo ""
  echo "Launch:  open '$APP_PATH'"
  echo ""
  echo "First time on this branch? Grant Input Monitoring + any other"
  echo "permissions you need in System Settings → Privacy & Security."
  echo "Permissions persist for this branch's path across rebuilds."
  echo "===================="
else
  echo "warning: expected app at $APP_PATH but it doesn't exist" >&2
  echo "(scheme '$SCHEME' may not produce OpenEmu.app — check the Build/Products/Debug dir)" >&2
  ls "$BUILD_DIR/Build/Products/Debug/" 2>/dev/null || true
fi
