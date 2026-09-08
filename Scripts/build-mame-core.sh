#!/usr/bin/env bash
# Build the OpenEmu MAME core from source for the current Mac by default.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MAME_DIR="$REPO_ROOT/MAME"
DD="$MAME_DIR/build/XcodeDerived"
TARGET_ARCH="${OPENEMU_ARCH:-$(uname -m)}"

if [ "${1:-}" = "--arch" ]; then
  [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: --arch requires arm64 or x86_64" >&2; exit 2; }
  TARGET_ARCH="$2"
  shift 2
fi
if [ $# -ne 0 ]; then
  echo "Usage: $0 [--arch arm64|x86_64]" >&2
  exit 2
fi

case "$TARGET_ARCH" in
  arm64) MAME_MAKE_TARGET="macosx_arm64_clang" ;;
  x86_64) MAME_MAKE_TARGET="macosx_x64_clang" ;;
  *) echo "error: unsupported architecture '$TARGET_ARCH'" >&2; exit 2 ;;
esac

# MAME's project generator mishandles absolute paths containing spaces. The
# repository often lives in "Open Emu", so transparently mirror the checkout to
# a temporary no-space path, build there, then copy the derived products back so
# install-core.sh and verify-core-installed.sh keep working from this checkout.
if [[ -z "${MAME_BUILD_NO_REEXEC:-}" && "$REPO_ROOT" =~ [[:space:]] ]]; then
  TMP_ROOT="$(mktemp -d /tmp/openemu-mame-build.XXXXXX)"
  TMP_REPO="$TMP_ROOT/repo"
  cleanup() {
    rm -rf "$TMP_ROOT"
  }
  trap cleanup EXIT

  echo "Repository path contains whitespace; building MAME from temporary path:"
  echo "  $TMP_REPO"
  mkdir -p "$TMP_REPO"
  rsync -a --delete \
    --exclude '.git' \
    --exclude 'MAME/deps' \
    --exclude 'MAME/build' \
    "$REPO_ROOT/" "$TMP_REPO/"

  OPENEMU_ARCH="$TARGET_ARCH" MAME_BUILD_NO_REEXEC=1 "$TMP_REPO/Scripts/build-mame-core.sh"

  rm -rf "$DD"
  mkdir -p "$(dirname "$DD")" "$MAME_DIR/deps/mame"
  rsync -a --delete "$TMP_REPO/MAME/build/XcodeDerived/" "$DD/"
  cp -f "$TMP_REPO/MAME/deps/mame/mamearcade_headless.dylib" "$MAME_DIR/deps/mame/mamearcade_headless.dylib"

  PLUGIN="$DD/Build/Products/Release/MAME.oecoreplugin"
  echo ""
  echo "Copied build products back to: $PLUGIN"
  file "$PLUGIN/Contents/MacOS/MAME"
  file "$PLUGIN/Contents/Frameworks/mamearcade_headless.dylib"
  "$SCRIPT_DIR/verify-bundle-architectures.sh" --arch "$TARGET_ARCH" "$PLUGIN"
  codesign --verify --deep --strict "$PLUGIN"
  exit 0
fi

"$SCRIPT_DIR/prepare-mame-core.sh"

cd "$MAME_DIR/deps/mame"
make NOWERROR=1 REGENIE=1 "$MAME_MAKE_TARGET" \
  OSD="headless" verbose=1 TARGETOS="macosx" CONFIG="release" \
  TARGET=mame SUBTARGET=arcade MACOSX_DEPLOYMENT_TARGET=11.0 \
  -j"$(sysctl -n hw.ncpu)"

install_name_tool -id mamearcade_headless.dylib mamearcade_headless.dylib

xcodebuild \
  -project "$REPO_ROOT/OpenEmu-SDK/OpenEmu-SDK.xcodeproj" \
  -scheme OpenEmuBase \
  -configuration Release \
  -derivedDataPath "$DD" \
  -destination "platform=macOS,arch=$TARGET_ARCH" \
  ONLY_ACTIVE_ARCH=YES ARCHS="$TARGET_ARCH" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" \
  build

xcodebuild \
  -project "$MAME_DIR/MAME.xcodeproj" \
  -scheme MAME \
  -configuration Release \
  -derivedDataPath "$DD" \
  -destination "platform=macOS,arch=$TARGET_ARCH" \
  ONLY_ACTIVE_ARCH=YES ARCHS="$TARGET_ARCH" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" \
  build

PLUGIN="$DD/Build/Products/Release/MAME.oecoreplugin"

echo ""
echo "Built: $PLUGIN"
file "$PLUGIN/Contents/MacOS/MAME"
file "$PLUGIN/Contents/Frameworks/mamearcade_headless.dylib"
"$SCRIPT_DIR/verify-bundle-architectures.sh" --arch "$TARGET_ARCH" "$PLUGIN"
codesign --verify --deep --strict "$PLUGIN"
