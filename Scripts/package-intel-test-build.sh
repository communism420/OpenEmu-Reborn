#!/usr/bin/env bash
# Package already-built Intel products for manual testing. No installation,
# release publication, feed updates, or changes to the input bundles.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APP=""
CORES=""
OUTPUT=""
SIGNING_MODE=""
SIGNING_IDENTITY=""

die() { echo "error: $*" >&2; exit 1; }
usage() { echo "Usage: $0 --app OpenEmu.app --cores <28 plugins directory> --output <new directory> (--signing-identity <40-hex certificate SHA-1> | --ad-hoc-sign)"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app|--cores|--output)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a path"
      case "$1" in
        --app) APP="$2" ;;
        --cores) CORES="$2" ;;
        --output) OUTPUT="$2" ;;
      esac
      shift 2 ;;
    --signing-identity)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a certificate SHA-1 fingerprint"
      [ -z "$SIGNING_MODE" ] || die "choose exactly one signing mode"
      SIGNING_MODE="certificate"
      SIGNING_IDENTITY="$2"
      shift 2 ;;
    --ad-hoc-sign)
      [ -z "$SIGNING_MODE" ] || die "choose exactly one signing mode"
      SIGNING_MODE="ad-hoc"
      SIGNING_IDENTITY="-"
      shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[ -n "$SIGNING_MODE" ] || die "explicit --signing-identity or --ad-hoc-sign is required"
if [ "$SIGNING_MODE" = "certificate" ]; then
  [[ "$SIGNING_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || die "signing identity must be an exact 40-hex certificate SHA-1 fingerprint"
  SIGNING_IDENTITY="$(printf '%s' "$SIGNING_IDENTITY" | tr '[:lower:]' '[:upper:]')"
  # Check the exact, valid identity before creating output. Never create keys,
  # change trust, select a similarly named certificate, or fall back to ad-hoc.
  identities=$(security find-identity -v -p codesigning) || die "could not inspect valid code-signing identities"
  printf '%s\n' "$identities" | awk -v expected="$SIGNING_IDENTITY" '
    $1 ~ /^[0-9]+\)$/ && toupper($2) == expected { found = 1 }
    END { exit !found }
  ' || die "the requested valid code-signing identity is unavailable"
fi

[ -f "$APP/Contents/MacOS/OpenEmu" ] || die "OpenEmu.app is missing"
[ -d "$CORES" ] || die "core input directory is missing"
[ -n "$OUTPUT" ] || die "--output is required"
[ ! -e "$OUTPUT" ] && [ ! -L "$OUTPUT" ] || die "output already exists; choose a new directory"

CORE_NAMES=(
  4DO Atari800 Bliss BSNES CrabEmu DeSmuME Dolphin FCEU Flycast Gambatte
  GenesisPlus JollyCV MAME Mednafen mGBA Mupen64Plus Nestopia O2EM Picodrive
  PokeMini Potator PPSSPP ProSystem SNES9x Stella VecXGL VirtualJaguar blueMSX
)
count=$(find "$CORES" -maxdepth 1 -name '*.oecoreplugin' -type d | wc -l | tr -d ' ')
[ "$count" -eq "${#CORE_NAMES[@]}" ] || die "expected 28 core bundles, found $count"
codesign --verify --deep --strict "$APP"
for core in "${CORE_NAMES[@]}"; do
  plugin="$CORES/$core.oecoreplugin"
  [ -d "$plugin" ] && [ ! -L "$plugin" ] || die "missing core bundle: $core"
  codesign --verify --deep --strict "$plugin"
done

commit=$(git -C "$REPO_ROOT" rev-parse HEAD)
workspace_state="clean"
workspace_changes=$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)
if [ -n "$workspace_changes" ]; then
  workspace_state="dirty (tracked or untracked changes are present)"
fi

mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
PACKAGE="$OUTPUT/OpenEmu-Intel-test"
STAGED_APP="$PACKAGE/OpenEmu.app"
mkdir "$PACKAGE"
ditto "$APP" "$STAGED_APP"
STAGED_CORES="$STAGED_APP/Contents/PlugIns/Cores"
# Never merge new cores with an existing set, even in the staging copy.
if [ -e "$STAGED_CORES" ]; then
  [ -d "$STAGED_CORES" ] && [ ! -L "$STAGED_CORES" ] || die "invalid embedded core directory"
  [ -z "$(find "$STAGED_CORES" -mindepth 1 -maxdepth 1 -print)" ] || die "app already has embedded cores"
fi
mkdir -p "$STAGED_CORES"
for core in "${CORE_NAMES[@]}"; do
  ditto "$CORES/$core.oecoreplugin" "$STAGED_CORES/$core.oecoreplugin"
done

"$SCRIPT_DIR/verify-bundle-architectures.sh" --arch x86_64 "$STAGED_APP"

# A build-machine path in a load command works on CI but fails on another Mac.
# Relative loader/rpath references are resolved by the app's normal layout;
# the clean-runner launch checks the host's dynamic loading separately.
while IFS= read -r -d '' binary; do
  if ! file -b "$binary" | grep -q 'Mach-O'; then
    continue
  fi
  while IFS= read -r dependency; do
    case "$dependency" in
      @rpath/*|@loader_path/*|@executable_path/*|/System/Library/*|/usr/lib/*) ;;
      *) die "non-portable dependency in $binary: $dependency" ;;
    esac
  done < <(otool -l "$binary" | awk '
    $1 == "cmd" { command = $2 }
    $1 == "name" && command ~ /^LC_(LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LOAD_UPWARD_DYLIB|LAZY_LOAD_DYLIB)$/ {
      sub(/^[[:space:]]*name[[:space:]]+/, "")
      sub(/[[:space:]]+\(offset [0-9]+\)$/, "")
      print
    }')
done < <(find "$STAGED_APP" -type f -print0)

# Preserve the existing hardened-runtime flags and nested helper signatures.
# Only the outer resource seal changed when the cores were embedded.
# Do not preserve old requirements: an ad-hoc requirement can bind permission
# to one old code hash instead of the explicitly selected certificate.
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none \
  --preserve-metadata=identifier,flags \
  --entitlements "$REPO_ROOT/OpenEmu/OpenEmu.entitlements" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
if [ "$SIGNING_MODE" = "certificate" ]; then
  # Test only the outer app against this leaf certificate. Nested cores keep
  # their original signatures; they must not be re-signed with --deep.
  codesign --verify --strict --test-requirement "=certificate leaf = H\"$SIGNING_IDENTITY\"" "$STAGED_APP"
  requirements=$(codesign --display --requirements - "$STAGED_APP" 2>&1) || die "could not read the new designated requirement"
  designated_requirement=$(printf '%s\n' "$requirements" | awk '
    /^#? ?designated => / { sub(/^# ?/, ""); print; found = 1 }
    END { exit !found }
  ') || die "certificate signature has no designated requirement"
  if printf '%s\n' "$designated_requirement" | grep -Eq '(^|[^[:alnum:]_])cdhash([^[:alnum:]_]|$)'; then
    die "certificate signature retained a code-hash-specific designated requirement"
  fi
  signing_description="certificate; SHA-1: $SIGNING_IDENTITY; not notarized"
else
  signing_description="ad-hoc; no stable publisher identity; not notarized"
fi
for core in "${CORE_NAMES[@]}"; do
  diff -qr --no-dereference "$CORES/$core.oecoreplugin" "$STAGED_CORES/$core.oecoreplugin" || die "packaging changed core bundle: $core"
done

ditto "$REPO_ROOT/docs/intel-test-build.md" "$PACKAGE/README.md"
ditto "$REPO_ROOT/LICENSE" "$PACKAGE/LICENSE"
printf 'Packaging checkout HEAD: %s\nPackaging working tree: %s\nInput provenance: supplied prebuilt app and cores; HEAD alone does not identify their source.\nArchitecture: x86_64\nConfiguration: Release\nBundled cores: 28; byte-identical to supplied core bundles\nSigning: %s\n' \
  "$commit" "$workspace_state" "$signing_description" > "$PACKAGE/BUILD-INFO.txt"

archive="OpenEmu-Reborn-Intel-test-${commit:0:12}.zip"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE" "$OUTPUT/$archive"
(cd "$OUTPUT" && shasum -a 256 "$archive" > "$archive.sha256")
echo "PASS: OpenEmu Reborn Intel test build packaged at $OUTPUT/$archive"
