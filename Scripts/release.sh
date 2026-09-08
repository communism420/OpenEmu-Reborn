#!/usr/bin/env bash
# release.sh — Full local release: archive → sign → notarize → DMG → appcast → GitHub draft
#
# Usage:
#   ./Scripts/release.sh <version>              # e.g. 1.0.4
#   ./Scripts/release.sh <version> [notes.md]  # optional release notes file
#
# What it does:
#   1. Archives the app with xcodebuild
#   2. Calls notarize.sh (re-sign, notarize, DMG, staple)
#   3. Runs sign_update to get the EdDSA signature
#   4. Prepends a new entry to appcast.xml
#   5. Commits/pushes metadata and immediately opens a draft PR
#   6. Tags that exact release commit
#   7. Creates a draft GitHub Release and uploads the DMG
#
# What it does NOT do:
#   - Publish the GitHub Release (stays as draft — you review and publish manually)
#   - Bump version numbers in the Xcode project (do that before running this script)
#
# Requirements:
#   - xcrun notarytool credentials stored under OPENEMU_NOTARY_PROFILE
#   - gh CLI authenticated: gh auth status
#   - Developer ID cert in your keychain

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPCAST="$REPO_ROOT/appcast.xml"
PLIST="$REPO_ROOT/OpenEmu/OpenEmu-Info.plist"
HELPER_PLIST="$REPO_ROOT/OpenEmu/OpenEmuHelperApp/OpenEmuHelperApp-Info.plist"
DMG_NAME="${OPENEMU_DMG_NAME:-OpenEmu-Intel.dmg}"
DMG="$REPO_ROOT/Releases/$DMG_NAME"
IDENTITY="${OPENEMU_SIGNING_IDENTITY:-Developer ID Application}"
DEVELOPMENT_TEAM="${OPENEMU_DEVELOPMENT_TEAM:-}"
NOTARY_PROFILE="${OPENEMU_NOTARY_PROFILE:-OpenEmu-Intel}"
RELEASE_REPO="${OPENEMU_RELEASE_REPO:-communism420/OpenEmu-Intel}"
RELEASE_WEB_URL="https://github.com/$RELEASE_REPO"
SENTRY_ORG="${OPENEMU_SENTRY_ORG:-}"
SENTRY_PROJECT="${OPENEMU_SENTRY_PROJECT:-}"
SENTRY_RELEASE_PREFIX="${OPENEMU_SENTRY_RELEASE_PREFIX:-openemu-intel}"

die() { echo ""; echo "ERROR: $*" >&2; exit 1; }
step() { echo ""; echo "══════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════"; }

# ── Args ──────────────────────────────────────────────────────────────────────
[ $# -ge 1 ] || die "Usage: $0 <version> [release-notes.md]"
VERSION="$1"
NOTES_FILE="${2:-}"

# Validate version format
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must be in format X.Y.Z (e.g. 1.0.4)"

# ── Find sign_update ──────────────────────────────────────────────────────────
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData \
  -path "*/artifacts/sparkle/Sparkle/bin/sign_update" \
  -not -path "*/old_dsa_scripts/*" \
  2>/dev/null | head -1)

# Fallback: search the repo's SPM cache
if [ -z "$SIGN_UPDATE" ]; then
  SIGN_UPDATE=$(find "$REPO_ROOT" -path "*/Sparkle/bin/sign_update" \
    -not -path "*/old_dsa_scripts/*" 2>/dev/null | head -1)
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

# Check gh CLI
gh auth status &>/dev/null || die "gh CLI not authenticated. Run: gh auth login"
echo "OK: gh CLI authenticated"

CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
RELEASE_BRANCH="chore/release-v$VERSION"
if [ "$CURRENT_BRANCH" = "main" ]; then
  echo "OK: on main — will create release branch $RELEASE_BRANCH"
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

# Warn if working tree is dirty (non-appcast files)
DIRTY=$(git -C "$REPO_ROOT" status --porcelain | grep -v "appcast.xml" | grep -v "Releases/" | grep -v "Dolphin/" | grep -v "OpenEmu-Info.plist" | grep -v "project.pbxproj" | grep -v "SECURITY.md" || true)
if [ -n "$DIRTY" ]; then
  echo ""
  echo "WARNING: Working tree has uncommitted changes:"
  echo "$DIRTY"
  echo ""
  read -r -p "Continue anyway? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# Verify CFBundleVersion in the plist matches the sparkle:version this script
# will write into the appcast. Catches the case where the plist was not bumped
# before running the release script, which causes Sparkle to loop forever.
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

if [ "$PLIST_BUILD_VERSION" != "$NEXT_VERSION" ]; then
  die "CFBundleVersion mismatch.
  OpenEmu-Info.plist has CFBundleVersion = \"$PLIST_BUILD_VERSION\"
  appcast.xml will write sparkle:version = \"$NEXT_VERSION\"
  These must match or Sparkle will offer the update in a loop.
  Fix: set CFBundleVersion to $NEXT_VERSION in OpenEmu-Info.plist before running this script."
fi
echo "OK: CFBundleVersion ($PLIST_BUILD_VERSION) matches next sparkle:version ($NEXT_VERSION)"

# ── 1. Archive ────────────────────────────────────────────────────────────────
step "1/5  Archiving OpenEmu (Release)"

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
step "2/5  Re-signing, notarizing, and creating DMG"

"$SCRIPT_DIR/notarize.sh" "$ARCHIVE_PATH"

[ -f "$DMG" ] || die "DMG not found at $DMG after notarize.sh. Check notarize.sh output above."

# ── 3. Sign for Sparkle ───────────────────────────────────────────────────────
step "3/5  Generating Sparkle EdDSA signature"

SIGN_OUTPUT=$("$SIGN_UPDATE" "$DMG" 2>&1)
echo "$SIGN_OUTPUT"

ED_SIG=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
DMG_LENGTH=$(echo "$SIGN_OUTPUT" | grep -o 'length="[0-9]*"' | cut -d'"' -f2)

[ -n "$ED_SIG" ]    || die "Could not parse edSignature from sign_update output."
[ -n "$DMG_LENGTH" ] || die "Could not parse length from sign_update output."

echo "edSignature: $ED_SIG"
echo "length:      $DMG_LENGTH"

# ── 4. Update appcast.xml ─────────────────────────────────────────────────────
step "4/5  Updating appcast.xml"

# NEXT_VERSION was already computed and validated in the preflight check above.
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

if [ -z "$NOTES_FILE" ] || [ ! -f "$NOTES_FILE" ]; then
  echo "NOTE: No release notes file provided. Appcast entry will contain a placeholder."
  echo "      Edit appcast.xml before publishing, or re-run with: $0 $VERSION path/to/notes.md"
fi

# Prepend new <item> to appcast.xml
OPENEMU_RELEASE_REPO="$RELEASE_REPO" OPENEMU_DMG_NAME="$DMG_NAME" \
python3 "$SCRIPT_DIR/update_appcast.py" \
  "$APPCAST" "$VERSION" "$NEXT_VERSION" "$PUB_DATE" "$ED_SIG" "$DMG_LENGTH" \
  ${NOTES_FILE:+"$NOTES_FILE"}

# ── 5. Commit to release branch, open PR, tag, and create GitHub draft release ─
step "5/5  Committing release metadata, opening PR, and creating GitHub draft release"

TAG="v$VERSION"

# Switch to (or create) the release branch so the commit goes through PR review
# rather than landing directly on main. CI lint and version checks run on the PR.
if [ "$CURRENT_BRANCH" = "main" ]; then
  git -C "$REPO_ROOT" checkout -b "$RELEASE_BRANCH"
fi

# Stage all release metadata files. The inherited openemu-silicon cask remains
# arm64-only and is intentionally not published as an Intel installation path.
git -C "$REPO_ROOT" add "$APPCAST" \
  "OpenEmu/OpenEmu-Info.plist" \
  "OpenEmu/OpenEmu.xcodeproj/project.pbxproj" \
  ".github/SECURITY.md"
if [ ! -f "$REPO_ROOT/Releases/notes-${VERSION}.md" ]; then
  die "Release notes not found: Releases/notes-${VERSION}.md — run prep-release first."
fi
git -C "$REPO_ROOT" add -f "Releases/notes-${VERSION}.md"
if git -C "$REPO_ROOT" diff --cached --quiet; then
  echo "No release metadata changes to commit; using current HEAD."
else
  git -C "$REPO_ROOT" commit -m "chore: release v$VERSION — update appcast and version bump"
fi

# Push the release branch
git -C "$REPO_ROOT" push -u origin "$RELEASE_BRANCH"

# Open the PR immediately after pushing the branch. If a previous run already
# created it, reuse that PR instead of failing partway through the release.
PR_NOTES=""
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
  PR_NOTES=$(cat "$NOTES_FILE")
fi

PR_URL=$(gh pr view "$RELEASE_BRANCH" \
  --repo "$RELEASE_REPO" \
  --json url \
  --jq .url 2>/dev/null || true)
if [ -z "$PR_URL" ]; then
  PR_URL=$(gh pr create \
    --repo "$RELEASE_REPO" \
    --base main \
    --head "$RELEASE_BRANCH" \
    --draft \
    --title "chore: release v$VERSION" \
    --body "## Release v$VERSION

This PR lands the appcast update and version files for v$VERSION. Merging makes the Sparkle update live for existing users.

**Before merging:**
- [ ] CI build check passes
- [ ] Draft GitHub Release reviewed — notes look good
- [ ] DMG tested (launch, quick smoke, check version in About)
- [ ] Draft GitHub Release published — appcast download URL is live

Publish before merging:
\`\`\`
gh release edit $TAG --draft=false --repo $RELEASE_REPO
\`\`\`

---
${PR_NOTES}")
fi

# Tag the release commit so the GitHub Release download URL is valid immediately.
# The tag points at this branch commit; after PR merges it remains reachable from main.
if git -C "$REPO_ROOT" tag -l | grep -qx "$TAG"; then
  TAG_TARGET=$(git -C "$REPO_ROOT" rev-list -n 1 "$TAG")
  HEAD_TARGET=$(git -C "$REPO_ROOT" rev-parse HEAD)
  [ "$TAG_TARGET" = "$HEAD_TARGET" ] || die "Tag $TAG already exists but does not point at HEAD. Delete or move it manually before continuing."
else
  echo "Creating git tag $TAG..."
  git -C "$REPO_ROOT" tag "$TAG"
fi
echo "Pushing tag $TAG..."
git -C "$REPO_ROOT" push origin "$TAG"

# Build release notes body for GitHub (use notes file if provided, else placeholder)
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
  GH_NOTES_ARGS=(--notes-file "$NOTES_FILE")
else
  GH_NOTES_ARGS=(--notes "Release notes — edit before publishing.")
fi

# Create or update GitHub draft release
if gh release view "$TAG" --repo "$RELEASE_REPO" &>/dev/null; then
  RELEASE_IS_DRAFT=$(gh release view "$TAG" \
    --repo "$RELEASE_REPO" \
    --json isDraft \
    --jq .isDraft)
  [ "$RELEASE_IS_DRAFT" = "true" ] \
    || die "Release $TAG is already published. Refusing to replace an immutable update asset."
  echo "Release $TAG already exists — uploading DMG and updating notes..."
  gh release upload "$TAG" "$DMG" \
    --repo "$RELEASE_REPO" \
    --clobber
  gh release edit "$TAG" \
    --repo "$RELEASE_REPO" \
    "${GH_NOTES_ARGS[@]}"
else
  echo "Creating draft release $TAG..."
  gh release create "$TAG" "$DMG" \
    --repo "$RELEASE_REPO" \
    --title "OpenEmu-Intel $VERSION" \
    --draft \
    "${GH_NOTES_ARGS[@]}"
fi

echo "DMG uploaded to draft release $TAG."

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Release $VERSION prepared — review PR then publish  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  DMG:    $DMG"
echo "  Tag:    $TAG (pushed; download URL becomes live after publishing the draft release)"
echo "  PR:     $PR_URL"
echo "  Draft:  $RELEASE_WEB_URL/releases/tag/$TAG"
echo ""
echo "  Next steps:"
echo "  1. Let CI run on the PR — check for version lint failures"
echo "  2. Review draft release notes on GitHub"
echo "  3. Test the DMG"
echo "  4. Publish the GitHub Release so its download URL is live:"
echo "     gh release edit $TAG --draft=false --repo $RELEASE_REPO"
echo "  5. Merge the PR (makes appcast live for Sparkle)"
echo ""
