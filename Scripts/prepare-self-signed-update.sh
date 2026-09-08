#!/usr/bin/env bash
# Package an existing certificate-signed app for Sparkle without Developer ID.
# Never builds/re-signs cores, installs an app, changes trust, or publishes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
die() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  echo "Usage: release.sh --self-signed <version> <notes.md> --app <OpenEmu.app> --arch arm64|x86_64|universal --signing-identity <40-hex SHA-1> --output <new directory> [--appcast <feed>]"
}
[ "$#" -ge 2 ] || { usage >&2; exit 2; }
VERSION="$1"
NOTES="$2"
shift 2
APP=""
ARCH=""
IDENTITY=""
OUTPUT=""
APPCAST="$REPO_ROOT/appcast.xml"
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"
  case "$1" in
    --app) APP="$2" ;;
    --arch) ARCH="$2" ;;
    --signing-identity) IDENTITY="$2" ;;
    --output) OUTPUT="$2" ;;
    --appcast) APPCAST="$2" ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift 2
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must be X.Y.Z"
case "$ARCH" in arm64|x86_64|universal) ;; *) die "An explicit supported architecture is required" ;; esac
[[ "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || die "Use the exact 40-hex certificate SHA-1, never a name or ad-hoc identity"
IDENTITY="$(printf '%s' "$IDENTITY" | tr '[:lower:]' '[:upper:]')"
[ -f "$NOTES" ] || die "A release-notes file is required"
[ -d "$APP" ] && [ ! -L "$APP" ] && [ -f "$APP/Contents/MacOS/OpenEmu" ] || die "Existing OpenEmu.app is required"
[ -n "$OUTPUT" ] && [ ! -e "$OUTPUT" ] && [ ! -L "$OUTPUT" ] || die "Choose a new, explicit output directory"
[ -f "$APPCAST" ] || die "Appcast file is missing"
if [ "$ARCH" = "x86_64" ] && [ "$(basename "$APPCAST")" != "appcast-x86_64.xml" ]; then
  die "Thin Intel apps cannot use the shared appcast. Build a universal app or configure a dedicated Intel feed."
fi

APP_PLIST="$APP/Contents/Info.plist"
APP_VERSION=$(python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleShortVersionString"])' "$APP_PLIST")
PUBLIC_KEY=$(python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["SUPublicEDKey"])' "$APP_PLIST")
[ "$APP_VERSION" = "$VERSION" ] || die "The supplied app version is $APP_VERSION, not $VERSION"
[[ "$PUBLIC_KEY" != "wVICc/NGoDFzkEbDb63QMFpKlRs14e/WhIiwIngQGsg=" ]] || die "The app still contains the inherited Sparkle key"
python3 "$SCRIPT_DIR/update_appcast.py" --validate-app "$APP" --arch "$ARCH" --appcast "$APPCAST"

# The prebuilt app must already have the selected stable certificate. Do not
# read private certificates, change trust, or silently re-sign with another key.
codesign --verify --deep --strict "$APP"
codesign --verify --strict --test-requirement "=certificate leaf = H\"$IDENTITY\"" "$APP"
requirements=$(codesign --display --requirements - "$APP" 2>&1)
if printf '%s\n' "$requirements" | grep -Eq '(^|[^[:alnum:]_])cdhash([^[:alnum:]_]|$)'; then
  die "The app has a build-specific code-hash requirement instead of a stable certificate identity"
fi
ARCHITECTURES=("$ARCH")
[ "$ARCH" != "universal" ] || ARCHITECTURES=(arm64 x86_64)
for architecture in "${ARCHITECTURES[@]}"; do
  bash "$SCRIPT_DIR/verify-bundle-architectures.sh" --arch "$architecture" "$APP"
done
CORE_NAMES=(4DO Atari800 Bliss BSNES CrabEmu DeSmuME Dolphin FCEU Flycast Gambatte
  GenesisPlus JollyCV MAME Mednafen mGBA Mupen64Plus Nestopia O2EM Picodrive
  PokeMini Potator PPSSPP ProSystem SNES9x Stella VecXGL VirtualJaguar blueMSX)
for core in "${CORE_NAMES[@]}"; do
  core_bundle="$APP/Contents/PlugIns/Cores/$core.oecoreplugin"
  [ -d "$core_bundle" ] && [ ! -L "$core_bundle" ] || die "Distribution is missing a real bundled core directory: $core"
done

SIGN_UPDATE="${OPENEMU_SIGN_UPDATE:-}"
if [ -z "$SIGN_UPDATE" ]; then
  SIGN_UPDATE=$(find "$REPO_ROOT/tmp" -path '*/artifacts/sparkle/Sparkle/bin/sign_update' -type f -print 2>/dev/null | head -1 || true)
fi
[ -n "$SIGN_UPDATE" ] && [ -x "$SIGN_UPDATE" ] || die "Set OPENEMU_SIGN_UPDATE to Sparkle's existing sign_update executable"
SPARKLE_ACCOUNT="${OPENEMU_SPARKLE_ACCOUNT:-org.openemu.Reborn.updates}"

mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
ARCHIVE="$OUTPUT/OpenEmu-Reborn-$ARCH.zip"
# Zip only the app, not a wrapping test-build folder. Sparkle installs this app.
# ditto preserves code seals; no additional .app copy is registered on the Mac.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
SIGN_OUTPUT=$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$ARCHIVE")
SIGNATURE=$(printf '%s\n' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
[ -n "$SIGNATURE" ] || die "Sparkle did not return an EdDSA signature"
MANIFEST="$OUTPUT/prepared-update-v$VERSION-$ARCH.json"
python3 "$SCRIPT_DIR/update_appcast.py" --prepare-manifest "$MANIFEST" \
  --app "$APP" --archive "$ARCHIVE" --signature "$SIGNATURE" \
  --arch "$ARCH" --notes "$NOTES" --appcast "$APPCAST" --certificate-sha1 "$IDENTITY"
echo "Archive: $ARCHIVE"
echo "Manifest: $MANIFEST"
echo "No app/core was built, installed or re-signed. No release or appcast was published."
echo "This archive is self-signed, not Apple-notarized. Initial installation may require macOS Open Anyway."
echo "Review and test it, then explicitly publish this exact archive to GitHub release v$VERSION."
echo "After publication, run: bash \"$SCRIPT_DIR/release.sh\" --advertise \"$MANIFEST\""
echo "The advertisement step checks the public archive's signature, URL, size and SHA-256."
