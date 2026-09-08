#!/usr/bin/env bash
# Prepare the MAME headless source used by MAME/MAME.xcodeproj.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MAME_DIR="$REPO_ROOT/MAME"
DEPS_DIR="$MAME_DIR/deps"
SRC_DIR="$DEPS_DIR/mame"
PATCH_FILE="$MAME_DIR/patches/mame-headless-clang21-apple.patch"
REVISION="4fc1f9f16b0dfba6be670367330028635613b04b"
REMOTE="https://github.com/stuartcarnie/mame.git"

mkdir -p "$DEPS_DIR"

if [ ! -e "$SRC_DIR/.git" ]; then
  echo "Initializing stuartcarnie/mame in $SRC_DIR..."
  git init -q "$SRC_DIR"
fi

cd "$SRC_DIR"

# Use a dedicated remote so an interrupted first run can repair itself without
# replacing a developer's existing origin (which may intentionally be a fork).
PINNED_REMOTE="openemu-pinned"
if git remote get-url "$PINNED_REMOTE" >/dev/null 2>&1; then
  git remote set-url "$PINNED_REMOTE" "$REMOTE"
else
  git remote add "$PINNED_REMOTE" "$REMOTE"
fi

# Fetch only the pinned revision. The complete upstream repository is over
# 1.5 GB, while this shallow checkout contains everything needed for the build
# and remains compatible with existing full clones.
if git cat-file -e "$REVISION^{commit}" 2>/dev/null; then
  echo "Pinned MAME revision is already available."
elif ! git rev-parse --verify HEAD >/dev/null 2>&1 || [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  git fetch --no-tags --depth=1 "$PINNED_REMOTE" "$REVISION"
else
  # Do not turn an existing full developer clone into a shallow repository.
  git fetch --no-tags "$PINNED_REMOTE" "$REVISION"
fi
git checkout --detach "$REVISION"

if git apply --check "$PATCH_FILE" >/dev/null 2>&1; then
  echo "Applying Apple Silicon / Clang 21 patch..."
  git apply "$PATCH_FILE"
elif git apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  echo "Patch already applied."
else
  echo "error: patch does not apply cleanly and is not already applied: $PATCH_FILE" >&2
  git status --short >&2 || true
  exit 1
fi

echo "MAME source ready at $SRC_DIR"
