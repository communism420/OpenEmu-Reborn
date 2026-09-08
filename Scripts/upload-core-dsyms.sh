#!/usr/bin/env bash
# upload-core-dsyms.sh — Build cores in Release and upload their dSYMs to Sentry.
#
# Use this to backfill dSYMs for any core whose Sentry upload was missed or skipped,
# and before every host-app release to ensure all currently-deployed core dSYMs are
# in Sentry so crashes can be symbolicated.
#
# Usage:
#   ./Scripts/upload-core-dsyms.sh                     # all cores in CORES list
#   ./Scripts/upload-core-dsyms.sh Mupen64Plus Snes9x  # specific cores only
#   ./Scripts/upload-core-dsyms.sh --dry-run            # show what would run; no credentials required
#   ./Scripts/upload-core-dsyms.sh --arch x86_64        # build for a specific CPU
#
# Prerequisites:
#   - sentry-cli installed and authenticated (sentry-cli info must pass)
#
# NOTE: This rebuilds each core from the current working tree in Release config.
# The resulting dSYMs match the rebuilt binary — not the previously released binary
# unless the source is unchanged. Run this immediately after releasing a core batch
# so the uploaded dSYMs match what users have installed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SENTRY_ORG="${OPENEMU_SENTRY_ORG:-}"
SENTRY_PROJECT="${OPENEMU_SENTRY_PROJECT:-}"

die()  { echo ""; echo "ERROR: $*" >&2; exit 1; }
ok()   { echo "PASS  $*"; }
warn() { echo "WARN  $*"; }
step() { echo ""; echo "──── $*"; }

# All in-repo cores with Release-buildable schemes.
ALL_CORES=(
  4DO
  Atari800
  Bliss
  BSNES
  CrabEmu
  DeSmuME
  Dolphin
  FCEU
  Flycast
  Gambatte
  GenesisPlus
  JollyCV
  mGBA
  Mednafen
  Mupen64Plus
  Nestopia
  O2EM
  PPSSPP
  Picodrive
  PokeMini
  Potator
  ProSystem
  SNES9x
  Stella
  VecXGL
  VirtualJaguar
  blueMSX
)

DRY_RUN=0
TARGET_ARCH="${OPENEMU_ARCH:-$(uname -m)}"
TARGET_CORES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --arch)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --arch requires arm64 or x86_64" >&2; exit 2; }
      TARGET_ARCH="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--arch arm64|x86_64] [CoreName ...]"
      echo "  No CoreName args → runs all cores: ${ALL_CORES[*]}"
      exit 0
      ;;
    *)
      TARGET_CORES+=("$1")
      shift
      ;;
  esac
done

case "$TARGET_ARCH" in
  arm64|x86_64) ;;
  *) die "unsupported architecture '$TARGET_ARCH' (expected arm64 or x86_64)" ;;
esac

# Use one explicit, architecture-specific DerivedData tree for the whole run.
# This prevents Xcode's hashed default path lookup from selecting a stale build
# or a dSYM produced for the other CPU architecture.
DERIVED_DATA="${OPENEMU_DSYM_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/OpenEmu-Intel-dSYMs-$TARGET_ARCH}"

if [ ${#TARGET_CORES[@]} -eq 0 ]; then
  TARGET_CORES=("${ALL_CORES[@]}")
fi

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight"

if [ "$DRY_RUN" -eq 0 ]; then
  [ -n "$SENTRY_ORG" ] && [ -n "$SENTRY_PROJECT" ] \
    || die "Set OPENEMU_SENTRY_ORG and OPENEMU_SENTRY_PROJECT before uploading dSYMs."
  command -v sentry-cli &>/dev/null \
    || die "sentry-cli not installed. Run: brew install getsentry/tools/sentry-cli"
  sentry-cli info &>/dev/null \
    || die "sentry-cli not authenticated. Run: sentry-cli login (or set SENTRY_AUTH_TOKEN)"

  ok "sentry-cli authenticated"
fi
echo "Cores to process: ${TARGET_CORES[*]}"
echo "Architecture: $TARGET_ARCH"
[ "$DRY_RUN" -eq 0 ] || echo "(DRY RUN — no builds or uploads)"

# ── Build host app in Release first (required by some cores) ──────────────────
if [ "$DRY_RUN" -eq 0 ]; then
  step "Building host app in Release (dependency for core builds)"
  HOST_BUILD_LOG=$(mktemp -t openemu-intel-host-dsym-build.XXXXXX)
  if xcodebuild \
    -workspace "$REPO_ROOT/OpenEmu-metal.xcworkspace" \
    -scheme OpenEmu \
    -configuration Release \
    -destination "platform=macOS,arch=$TARGET_ARCH" \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="$TARGET_ARCH" \
    ONLY_ACTIVE_ARCH=YES \
    build >"$HOST_BUILD_LOG" 2>&1; then
    HOST_BUILD_STATUS=0
  else
    HOST_BUILD_STATUS=$?
  fi
  grep -E "(BUILD (SUCCEEDED|FAILED)|error:|warning:)" "$HOST_BUILD_LOG" | tail -10 || true
  if [ "$HOST_BUILD_STATUS" -ne 0 ]; then
    tail -80 "$HOST_BUILD_LOG" >&2
    die "Host app Release build failed with status $HOST_BUILD_STATUS. Full log: $HOST_BUILD_LOG"
  fi
  rm -f "$HOST_BUILD_LOG"
  ok "Host app Release build complete"
fi

# ── Process each core ─────────────────────────────────────────────────────────
PASSED=()
FAILED=()

for CORE in "${TARGET_CORES[@]}"; do
  echo ""
  echo "════════════════════════════════════"
  echo "  $CORE"
  echo "════════════════════════════════════"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "(dry run) would: build Release → verify plugin architecture → upload dSYM to Sentry"
    PASSED+=("$CORE")
    continue
  fi

  SCHEME="OpenEmu + $CORE"
  case "$CORE" in
    DeSmuME|Dolphin) SCHEME="$CORE" ;;
  esac

  # Build the core in Release
  step "Building $CORE in Release"
  CORE_BUILD_LOG=$(mktemp -t "openemu-intel-${CORE}-dsym-build.XXXXXX")
  if xcodebuild \
    -workspace "$REPO_ROOT/OpenEmu-metal.xcworkspace" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "platform=macOS,arch=$TARGET_ARCH" \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="$TARGET_ARCH" \
    ONLY_ACTIVE_ARCH=YES \
    build >"$CORE_BUILD_LOG" 2>&1; then
    CORE_BUILD_STATUS=0
  else
    CORE_BUILD_STATUS=$?
  fi
  grep -E "(BUILD (SUCCEEDED|FAILED)|error:|warning:)" "$CORE_BUILD_LOG" | tail -10 || true
  if [ "$CORE_BUILD_STATUS" -ne 0 ]; then
    tail -80 "$CORE_BUILD_LOG" >&2
    warn "$CORE: build failed — skipping dSYM upload"
    FAILED+=("$CORE")
    continue
  fi
  rm -f "$CORE_BUILD_LOG"

  # Verify the plugin exists
  PLUGIN="$DERIVED_DATA/Build/Products/Release/${CORE}.oecoreplugin"
  if [ ! -d "$PLUGIN" ]; then
    warn "$CORE: plugin not found at $PLUGIN after build — skipping"
    FAILED+=("$CORE")
    continue
  fi

  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" \
    "$PLUGIN/Contents/Info.plist" 2>/dev/null || true)
  if [ -z "$VERSION" ]; then
    warn "$CORE: built plugin has no CFBundleVersion — skipping dSYM upload"
    FAILED+=("$CORE")
    continue
  fi
  echo "Built version: $VERSION"

  if ! "$SCRIPT_DIR/verify-bundle-architectures.sh" --arch "$TARGET_ARCH" "$PLUGIN"; then
    warn "$CORE: plugin contains a binary for the wrong architecture — skipping"
    FAILED+=("$CORE")
    continue
  fi

  # Upload the rebuilt plugin's dSYM and verify its debug identifiers.
  step "Uploading dSYM for $CORE to Sentry"
  if "$SCRIPT_DIR/verify-sentry-symbols.sh" \
    --upload \
    --wait-for 60 \
    --org "$SENTRY_ORG" \
    --project "$SENTRY_PROJECT" \
    --binary-root "$PLUGIN" \
    --dsym-root "$DERIVED_DATA/Build/Products/Release"; then
    ok "$CORE $VERSION — dSYM uploaded"
    PASSED+=("$CORE")
  else
    warn "$CORE: dSYM upload failed"
    FAILED+=("$CORE")
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════"
echo "  Summary"
echo "════════════════════════════════════"
echo "  Passed:  ${#PASSED[@]}  — ${PASSED[*]:-none}"
echo "  Failed:  ${#FAILED[@]}  — ${FAILED[*]:-none}"

if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  echo "  Some cores failed. Re-run for specific cores:"
  for c in "${FAILED[@]}"; do
    echo "    $0 $c"
  done
  exit 1
fi

echo ""
echo "All core dSYMs processed. Sentry will symbolicate crashes for the rebuilt cores."
