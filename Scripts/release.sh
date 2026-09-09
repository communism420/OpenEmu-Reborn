#!/usr/bin/env bash
# release.sh — Prepare a signed archive, then advertise it only after publication.
#
# Usage:
#   ./Scripts/release.sh <version> <notes.md>  # paid, notarized mode
#   ./Scripts/release.sh --self-signed <version> <notes.md> --app <app> \
#       --arch universal --signing-identity <exact SHA-1> --output <new directory>
#   ./Scripts/release.sh --advertise <prepared-update.json>
#
# What it does:
#   1. Archives the app with xcodebuild
#   2. Calls notarize.sh (re-sign, notarize, DMG, staple)
#   3. Runs sign_update to get the EdDSA signature
#   4. Saves verified update metadata beside the archive
#   5. Prints the explicit draft/publication steps (no Git or GitHub writes)
#
# What it does NOT do:
#   - Publish a GitHub Release, tag, push, commit or open a PR
#   - Advertise a draft, missing or mismatched archive in the live appcast
#   - Rebuild cores (the self-signed path does not build the host either)
#   - Bump version numbers in the Xcode project (do that before running this script)
#
# Requirements for the default notarized mode only:
#   - xcrun notarytool credentials stored under OPENEMU_NOTARY_PROFILE
#   - Developer ID cert in your keychain

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
if [ "${1:-}" = "--self-signed" ]; then
  shift
  exec bash "$SCRIPT_DIR/prepare-self-signed-update.sh" "$@"
elif [ "${1:-}" = "--advertise" ]; then
  [ "$#" -eq 2 ] || { echo "Usage: $0 --advertise <prepared-update.json>" >&2; exit 2; }
  exec python3 "$SCRIPT_DIR/update_appcast.py" --manifest "$2"
fi
APPCAST="$REPO_ROOT/appcast.xml"
PLIST="$REPO_ROOT/OpenEmu/OpenEmu-Info.plist"
HELPER_PLIST="$REPO_ROOT/OpenEmu/OpenEmuHelperApp/OpenEmuHelperApp-Info.plist"
DMG_NAME="${OPENEMU_DMG_NAME:-OpenEmu-Reborn.dmg}"
DMG="$REPO_ROOT/Releases/$DMG_NAME"
IDENTITY="${OPENEMU_SIGNING_IDENTITY:-Developer ID Application}"
DEVELOPMENT_TEAM="${OPENEMU_DEVELOPMENT_TEAM:-}"
NOTARY_PROFILE="${OPENEMU_NOTARY_PROFILE:-OpenEmu-Intel}"
RELEASE_REPO="${OPENEMU_RELEASE_REPO:-communism420/OpenEmu-Reborn}"
SENTRY_ORG="${OPENEMU_SENTRY_ORG:-}"
SENTRY_PROJECT="${OPENEMU_SENTRY_PROJECT:-}"
SENTRY_RELEASE_PREFIX="${OPENEMU_SENTRY_RELEASE_PREFIX:-openemu-intel}"
SPARKLE_ACCOUNT="${OPENEMU_SPARKLE_ACCOUNT:-org.openemu.Reborn.updates}"

die() { echo ""; echo "ERROR: $*" >&2; exit 1; }
step() { echo ""; echo "══════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════"; }

# ── Args ──────────────────────────────────────────────────────────────────────
[ $# -eq 2 ] || die "Usage: $0 <version> <release-notes.md>"
VERSION="$1"
NOTES_FILE="${2:-}"
[ -f "$NOTES_FILE" ] || die "Provide a release-notes file; placeholder notes are not publishable."
[ ! -e "$DMG" ] && [ ! -L "$DMG" ] || die "Release archive already exists: $DMG. Preserve the old signed artifact and choose OPENEMU_DMG_NAME explicitly."
[ ! -e "$REPO_ROOT/Releases/prepared-update-v$VERSION-universal.json" ] \
  || die "Prepared metadata already exists for this version; do not rebuild an already signed release."

# Validate version format
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must be in format X.Y.Z (e.g. 1.0.4)"

# ── Find sign_update ──────────────────────────────────────────────────────────
SIGN_UPDATE=${OPENEMU_SIGN_UPDATE:-$(find ~/Library/Developer/Xcode/DerivedData \
  -path "*/artifacts/sparkle/Sparkle/bin/sign_update" \
  -not -path "*/old_dsa_scripts/*" \
  2>/dev/null | head -1 || true)}

# Fallback: search the repo's SPM cache
if [ -z "$SIGN_UPDATE" ]; then
  SIGN_UPDATE=$(find "$REPO_ROOT" -path "*/Sparkle/bin/sign_update" \
    -not -path "*/old_dsa_scripts/*" 2>/dev/null | head -1 || true)
fi

[ -n "$SIGN_UPDATE" ] || die "sign_update not found. Build the project in Xcode first to resolve the Sparkle package."
echo "sign_update: $SIGN_UPDATE"

# ── Preflight checks ─────────────────────────────────────────────────────────
step "Preflight checks"

# Require the fork maintainer's signing team explicitly. Never fall back to the
# upstream maintainer's team ID from the inherited release script.
[ -n "$DEVELOPMENT_TEAM" ] \
  || die "OPENEMU_DEVELOPMENT_TEAM is required (your 10-character Apple Developer Team ID)."

# Check notarytool credentials
# Credentials are stored in the keychain under the selected notary profile from a prior run of:
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id <id> --team-id <team-id> --password <app-specific-password>
# App-specific passwords are generated at appleid.apple.com → Security → App-Specific Passwords.
# If you see a 403 error here, a Developer Program agreement likely needs re-acceptance at
# appstoreconnect.apple.com (look for a banner at the top of the page).
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null \
  || die "No notarytool credentials found. Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id $DEVELOPMENT_TEAM --password <app-specific-password>"
echo "OK: notarytool credentials"

CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
RELEASE_BRANCH="codex/release-v$VERSION"
if [ "$CURRENT_BRANCH" = "main" ]; then
  echo "OK: on main (preparation will not modify Git)"
elif [ "$CURRENT_BRANCH" = "$RELEASE_BRANCH" ]; then
  echo "OK: already on release branch $RELEASE_BRANCH"
else
  die "release.sh must run from main or $RELEASE_BRANCH. Current branch: $CURRENT_BRANCH"
fi

# Sentry is opt-in for this fork. Supplying one of these values without the
# other is almost certainly a configuration mistake; supplying neither skips
# upload and, importantly, never writes to the upstream project's Sentry org.
SENTRY_ENABLED=0
if [ -n "$SENTRY_ORG" ] || [ -n "$SENTRY_PROJECT" ]; then
  [ -n "$SENTRY_ORG" ] && [ -n "$SENTRY_PROJECT" ] \
    || die "Set both OPENEMU_SENTRY_ORG and OPENEMU_SENTRY_PROJECT, or neither."
  command -v sentry-cli &>/dev/null \
    || die "sentry-cli is not installed. Install with: brew install getsentry/tools/sentry-cli"
  sentry-cli info &>/dev/null \
    || die "sentry-cli is not authenticated. Run: sentry-cli login (or set SENTRY_AUTH_TOKEN)."

  MAIN_SENTRY_DSN=$(/usr/libexec/PlistBuddy -c "Print OESentryDSN" "$PLIST" 2>/dev/null || true)
  HELPER_SENTRY_DSN=$(/usr/libexec/PlistBuddy -c "Print OESentryDSN" "$HELPER_PLIST" 2>/dev/null || true)
  MAIN_SENTRY_PREFIX=$(/usr/libexec/PlistBuddy -c "Print OESentryReleasePrefix" "$PLIST" 2>/dev/null || true)
  HELPER_SENTRY_PREFIX=$(/usr/libexec/PlistBuddy -c "Print OESentryReleasePrefix" "$HELPER_PLIST" 2>/dev/null || true)
  [ -n "$MAIN_SENTRY_DSN" ] && [ "$MAIN_SENTRY_DSN" = "$HELPER_SENTRY_DSN" ] \
    || die "Configure the same fork-owned OESentryDSN in the app and helper Info.plists before enabling Sentry uploads."
  [ "$MAIN_SENTRY_PREFIX" = "$SENTRY_RELEASE_PREFIX" ] && [ "$HELPER_SENTRY_PREFIX" = "$SENTRY_RELEASE_PREFIX" ] \
    || die "OESentryReleasePrefix must equal OPENEMU_SENTRY_RELEASE_PREFIX ('$SENTRY_RELEASE_PREFIX') in both Info.plists."
  SENTRY_ENABLED=1
  echo "OK: sentry-cli authenticated for $SENTRY_ORG/$SENTRY_PROJECT"
else
  echo "SKIP: Sentry upload (set OPENEMU_SENTRY_ORG and OPENEMU_SENTRY_PROJECT to enable)"
fi

# Check cert
security find-identity -v | grep -q "Developer ID Application" \
  || die "Developer ID Application certificate not found in keychain."
echo "OK: Developer ID certificate"

# Release sources must already have been reviewed and committed.
DIRTY=$(git -C "$REPO_ROOT" status --porcelain)
if [ -n "$DIRTY" ]; then
  die "Commit reviewed release sources through a PR before preparing a release. Working tree is not clean."
fi

# Use the actual app build number and require monotonic publication. Private
# test builds may have consumed numbers that were never in the public feed.
PLIST_BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST" 2>/dev/null || true)
PLIST_MARKETING_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST" 2>/dev/null || true)
SPARKLE_PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "$PLIST" 2>/dev/null || true)
INHERITED_SPARKLE_PUBLIC_KEY="wVICc/NGoDFzkEbDb63QMFpKlRs14e/WhIiwIngQGsg="

if [ -z "$SPARKLE_PUBLIC_KEY" ] || [ "$SPARKLE_PUBLIC_KEY" = "$INHERITED_SPARKLE_PUBLIC_KEY" ]; then
  die "Configure this fork's Sparkle EdDSA key before releasing.
  Run Sparkle's generate_keys tool, keep the private key outside git, and replace
  SUPublicEDKey in OpenEmu/OpenEmu-Info.plist with the generated public key."
fi

[ "$PLIST_MARKETING_VERSION" = "$VERSION" ] \
  || die "CFBundleShortVersionString mismatch: app has '$PLIST_MARKETING_VERSION', release argument is '$VERSION'."

CURRENT_MAX=$(grep -o 'sparkle:version="[0-9]*"' "$APPCAST" | grep -o '[0-9]*' | sort -n | tail -1)
NEXT_VERSION=$((CURRENT_MAX + 1))

[[ "$PLIST_BUILD_VERSION" =~ ^[1-9][0-9]*$ ]] && [ "$PLIST_BUILD_VERSION" -ge "$NEXT_VERSION" ] \
  || die "CFBundleVersion must be an integer greater than every published build ($CURRENT_MAX)."
NEXT_VERSION="$PLIST_BUILD_VERSION"
echo "OK: appcast will use the app's actual CFBundleVersion ($NEXT_VERSION)"

# ── 1. Archive ────────────────────────────────────────────────────────────────
step "1/4  Archiving OpenEmu (Release)"

ARCHIVE_PATH="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/OpenEmu-Intel-$VERSION.xcarchive"
mkdir -p "$(dirname "$ARCHIVE_PATH")"

ARCHIVE_LOG=$(mktemp -t openemu-intel-archive.XXXXXX)
if xcodebuild archive \
  -workspace "$REPO_ROOT/OpenEmu-metal.xcworkspace" \
  -scheme OpenEmu \
  -configuration Release \
  -destination generic/platform=macOS \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  ENABLE_HARDENED_RUNTIME=YES \
  >"$ARCHIVE_LOG" 2>&1; then
  ARCHIVE_STATUS=0
else
  ARCHIVE_STATUS=$?
fi
grep -E "(ARCHIVE (SUCCEEDED|FAILED)|error:|warning:)" "$ARCHIVE_LOG" | tail -20 || true
if [ "$ARCHIVE_STATUS" -ne 0 ]; then
  tail -80 "$ARCHIVE_LOG" >&2
  die "xcodebuild archive failed with status $ARCHIVE_STATUS. Full log: $ARCHIVE_LOG"
fi
rm -f "$ARCHIVE_LOG"

[ -d "$ARCHIVE_PATH" ] || die "Archive not found at expected path: $ARCHIVE_PATH"
echo "Archive: $ARCHIVE_PATH"

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/OpenEmu.app"
"$SCRIPT_DIR/verify-bundle-architectures.sh" --arch arm64 "$ARCHIVED_APP"
"$SCRIPT_DIR/verify-bundle-architectures.sh" --arch x86_64 "$ARCHIVED_APP"

# ── 1.5. Verify dSYMs and optionally upload to Sentry ─────────────────────────
step "Verifying dSYMs"

DERIVED_DATA=$(ls -td ~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-* 2>/dev/null | head -1 || true)
SYMBOL_ARGS=(
  --binary-root "$ARCHIVED_APP"
  --dsym-root "$ARCHIVE_PATH/dSYMs"
  --generated-dsym-root "$ARCHIVE_PATH/dSYMs/Generated"
)
if [ -n "$DERIVED_DATA" ]; then
  # Includes dSYMs supplied by binary dependencies such as Sentry's xcframework.
  SYMBOL_ARGS+=(--dsym-root "$DERIVED_DATA")
fi
if [ "$SENTRY_ENABLED" -eq 1 ]; then
  SYMBOL_ARGS+=(
    --upload
    --wait-for 120
    --org "$SENTRY_ORG"
    --project "$SENTRY_PROJECT"
  )
fi
"$SCRIPT_DIR/verify-sentry-symbols.sh" "${SYMBOL_ARGS[@]}"

# ── 1.6. Register release in Sentry ──────────────────────────────────────────
# Sentry uses this marker to show "First seen in vX.Y.Z" on issues, link
# suspect commits between the previous tag and HEAD, and track per-release
# crash-free session rates. The release prefix must match SentryService.swift
# and both Info.plists exactly.
if [ "$SENTRY_ENABLED" -eq 1 ]; then
  step "Registering release marker in Sentry"

  SENTRY_RELEASE="${SENTRY_RELEASE_PREFIX}@${VERSION}+${PLIST_BUILD_VERSION}"
  sentry-cli releases new "$SENTRY_RELEASE" \
    --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" \
    || echo "WARNING: sentry-cli releases new failed — Sentry crash tracking will work but release metadata won't show."
  sentry-cli releases set-commits "$SENTRY_RELEASE" --auto \
    --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" \
    || echo "WARNING: sentry-cli releases set-commits failed — suspect commit linking won't work for this release."
  sentry-cli releases finalize "$SENTRY_RELEASE" \
    --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" \
    || echo "WARNING: sentry-cli releases finalize failed."
  echo "OK: Sentry release marker: $SENTRY_RELEASE"
fi

# ── 2. Notarize (re-sign + notarize + DMG + staple) ──────────────────────────
step "2/4  Re-signing, notarizing, and creating DMG"

"$SCRIPT_DIR/notarize.sh" "$ARCHIVE_PATH"

[ -f "$DMG" ] || die "DMG not found at $DMG after notarize.sh. Check notarize.sh output above."

# ── 3. Sign for Sparkle ───────────────────────────────────────────────────────
step "3/4  Generating Sparkle EdDSA signature"

SIGN_OUTPUT=$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$DMG" 2>&1)
echo "$SIGN_OUTPUT"

ED_SIG=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
DMG_LENGTH=$(echo "$SIGN_OUTPUT" | grep -o 'length="[0-9]*"' | cut -d'"' -f2)

[ -n "$ED_SIG" ]    || die "Could not parse edSignature from sign_update output."
[ -n "$DMG_LENGTH" ] || die "Could not parse length from sign_update output."

echo "edSignature: $ED_SIG"
echo "length:      $DMG_LENGTH"

# Signing with a different Keychain account must fail here, not on users' Macs.
swift "$SCRIPT_DIR/verify-update-signature.swift" "$DMG" "$SPARKLE_PUBLIC_KEY" "$ED_SIG"

# ── 4. Prepare metadata without advertising an unavailable archive ────────────
step "4/4  Saving verified release metadata"
MANIFEST="$REPO_ROOT/Releases/prepared-update-v$VERSION-universal.json"
python3 "$SCRIPT_DIR/update_appcast.py" --prepare-manifest "$MANIFEST" \
  --app "$ARCHIVED_APP" --archive "$DMG" --signature "$ED_SIG" \
  --arch universal --notes "$NOTES_FILE" --appcast "$APPCAST"

echo "Prepared archive: $DMG"
echo "Update metadata: $MANIFEST"
echo "No Git or GitHub state was changed."
echo "Review and test the archive before creating/publishing the release."
echo "Once published, run: $0 --advertise \"$MANIFEST\""
echo "That command checks the public archive before updating appcast.xml."
echo "Commit the appcast change on a new codex/ branch and open a PR against main."
