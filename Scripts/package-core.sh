#!/usr/bin/env bash
# package-core.sh — Sign, upload dSYM to Sentry, and zip a built core plugin for release.
#
# Run this after an explicit universal Release build. For example:
#
#   xcodebuild build -workspace OpenEmu-metal.xcworkspace \
#     -scheme "OpenEmu + Gambatte" -configuration Release \
#     -destination generic/platform=macOS \
#     -derivedDataPath "$PWD/.derived-data" \
#     ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO
#
# The script produces a signed, universal zip at
# /tmp/<CoreName>.oecoreplugin.zip.
# The explicit DerivedData path prevents an old build from being packaged by
# accident. Shared appcasts must only contain universal core archives.
#
# Usage:
#   OPENEMU_DERIVED_DATA_PATH=/path/to/DerivedData ./Scripts/package-core.sh <CoreName> <Version>
#
# Example:
#   OPENEMU_DERIVED_DATA_PATH="$PWD/.derived-data" ./Scripts/package-core.sh Gambatte 0.5.3
#
# Prerequisites:
#   - Core built as a universal Release bundle (arm64 + x86_64)
#   - Developer ID Application cert in keychain
#   - sentry-cli only when OPENEMU_SENTRY_ORG/PROJECT enable upload

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die()  { echo ""; echo "ERROR: $*" >&2; exit 1; }
ok()   { echo "PASS  $*"; }
warn() { echo "WARN  $*"; }
step() { echo ""; echo "──── $*"; }

[ $# -eq 2 ] || die "Usage: $0 <CoreName> <Version>  (e.g. $0 Gambatte 0.5.3)"
CORE="$1"
VERSION="$2"

# ── 1. Locate the Release artifact ───────────────────────────────────────────
step "Locating Release artifact"

DERIVED_DATA="${OPENEMU_DERIVED_DATA_PATH:-}"
[ -n "$DERIVED_DATA" ] || die "OPENEMU_DERIVED_DATA_PATH is required.
  Point it at the exact DerivedData directory used for this release build;
  automatic discovery is intentionally disabled to prevent stale packaging."
[ -d "$DERIVED_DATA" ] || die "DerivedData directory not found: $DERIVED_DATA"

PLUGIN="$DERIVED_DATA/Build/Products/Release/${CORE}.oecoreplugin"
[ -d "$PLUGIN" ] || die "Plugin not found: $PLUGIN — run the universal xcodebuild command documented at the top of this script."
ok "Found: $PLUGIN"

"$SCRIPT_DIR/verify-bundle-architectures.sh" --arch arm64 "$PLUGIN" \
  || die "Plugin is not universal: an arm64 slice is missing."
"$SCRIPT_DIR/verify-bundle-architectures.sh" --arch x86_64 "$PLUGIN" \
  || die "Plugin is not universal: an x86_64 slice is missing."
ok "All plugin binaries contain arm64 and x86_64"

# ── 2. Verify CFBundleVersion matches ────────────────────────────────────────
step "Verifying CFBundleVersion"

BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" \
  "$PLUGIN/Contents/Info.plist" 2>/dev/null || true)
[ "$BUILT_VERSION" = "$VERSION" ] \
  || die "CFBundleVersion mismatch: plugin has '$BUILT_VERSION', expected '$VERSION'.
  Did the plist bump land in this build? Clean and repeat the universal Release build."
ok "CFBundleVersion = $BUILT_VERSION"

# ── 3. Sign with Developer ID Application ────────────────────────────────────
step "Signing with Developer ID"

# Set OPENEMU_SIGNING_IDENTITY to a full certificate name when multiple
# Developer ID identities are installed. Never hard-code an upstream team.
IDENTITY="${OPENEMU_SIGNING_IDENTITY:-Developer ID Application}"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || die "Developer ID Application certificate not found in keychain.
  Check with: security find-identity -v | grep 'Developer ID Application'"

codesign --force --sign "$IDENTITY" --options runtime --timestamp "$PLUGIN"
codesign --verify --deep --strict "$PLUGIN" \
  && ok "codesign --verify passed" \
  || die "codesign --verify failed after signing. Bundle may be malformed."

# ── 4. Verify and upload dSYM to Sentry ──────────────────────────────────────
step "Verifying dSYM"

SENTRY_ARGS=(
  --binary-root "$PLUGIN"
  --dsym-root "$DERIVED_DATA/Build/Products/Release"
  --allow-missing '\.so$'
)
if [ -n "${OPENEMU_SENTRY_ORG:-}" ] || [ -n "${OPENEMU_SENTRY_PROJECT:-}" ]; then
  [ -n "${OPENEMU_SENTRY_ORG:-}" ] && [ -n "${OPENEMU_SENTRY_PROJECT:-}" ] \
    || die "Set both OPENEMU_SENTRY_ORG and OPENEMU_SENTRY_PROJECT, or neither."
  SENTRY_ARGS+=(
    --upload
    --wait-for 120
    --org "$OPENEMU_SENTRY_ORG"
    --project "$OPENEMU_SENTRY_PROJECT"
  )
else
  warn "Sentry upload disabled; set OPENEMU_SENTRY_ORG and OPENEMU_SENTRY_PROJECT to enable it."
fi

"$SCRIPT_DIR/verify-sentry-symbols.sh" "${SENTRY_ARGS[@]}"

# ── 5. Zip with ditto ────────────────────────────────────────────────────────
step "Creating zip"

ZIP="/tmp/${CORE}.oecoreplugin.zip"
rm -f "$ZIP"
ditto -c -k --keepParent --norsrc "$PLUGIN" "$ZIP"
ok "Zip: $ZIP"

# ── 6. Verify zip contents ───────────────────────────────────────────────────
step "Verifying zip"

VERIFY_DIR=$(mktemp -d)
ditto -x -k "$ZIP" "$VERIFY_DIR"
ZIP_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" \
  "$VERIFY_DIR/${CORE}.oecoreplugin/Contents/Info.plist" 2>/dev/null || true)
rm -rf "$VERIFY_DIR"

[ "$ZIP_VERSION" = "$VERSION" ] \
  || die "Zip version mismatch: zip contains '$ZIP_VERSION', expected '$VERSION'. Do not upload this zip."
ok "Zip CFBundleVersion = $ZIP_VERSION"

# ── Done ─────────────────────────────────────────────────────────────────────
BYTE_COUNT=$(wc -c < "$ZIP" | tr -d ' ')

echo ""
echo "══════════════════════════════════════════════"
echo "  $CORE $VERSION packaged successfully"
echo "══════════════════════════════════════════════"
echo "  Zip:   $ZIP"
echo "  Bytes: $BYTE_COUNT"
echo ""
echo "This is a manual release artifact. The fork currently keeps Apple Silicon"
echo "cores on the OpenEmu-Silicon feeds and Intel cores on the legacy official"
echo "feeds, so uploading this zip does not publish it to either architecture."
echo "Do not change a shared appcast until the fork has an architecture-aware"
echo "core feed and catalog."
