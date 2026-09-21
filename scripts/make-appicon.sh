#!/usr/bin/env bash
#
# make-appicon.sh — generate CleanMac's AppIcon.appiconset PNGs from a source
# image using only native macOS `sips`. Dependency-free and idempotent.
#
# Usage (repo convention is to invoke via bash):
#   bash scripts/make-appicon.sh [<source-image>]
#
# <source-image> defaults to the user-provided broom JPEG in ~/Downloads.
#
# Pipeline (design Option A — full-bleed square, let macOS do the only rounding):
#   1. center-square crop with a small inset to shave the artwork's baked
#      rounded corners (so no white/transparent corner sliver survives),
#   2. upscale once to a 1024x1024 PNG master,
#   3. downscale-only from the master into the 7 distinct pixel sizes,
#   4. map those to the 10 slot filenames (byte-identical copies for shared
#      sizes),
#   5. verify all 10 exist at exact sizes in a scratch dir, then atomically
#      copy them into the appiconset — leaving the set untouched on any failure.

set -euo pipefail

# ----------------------------------------------------------------------------
# Resolve paths relative to the repo root (parent of this script's dir) so the
# script works when invoked as `bash scripts/make-appicon.sh` from repo root.
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC="${1:-$HOME/Downloads/134903f2-e132-41cd-a54d-5fb03236241c.jpeg}"
SET="$REPO_ROOT/CleanMac/Resources/Assets.xcassets/AppIcon.appiconset"

# Crop geometry (Option A — full-bleed blue square, no white corner sliver).
#
# The source's blue rounded-square artwork is NOT full-width and NOT vertically
# centered: measured blue bounding box is x[96..623], y[332..764] (~527x432),
# centered at (~359, ~548). A naive center square crop grabs white margins and
# leaves white corners, so we crop an explicit OFFSET square that sits just
# inside the blue (shaving its baked rounded corners) via sips --cropOffset.
#
# CROP  = side length of the square to cut from the source (px).
# OFF_X = left offset of that square in the source.
# OFF_Y = top offset of that square in the source.
# Defaults inset the square inside the blue box so every corner is solid blue.
CROP="${CROP:-380}"
OFF_X="${OFF_X:-169}"
OFF_Y="${OFF_Y:-358}"

# ----------------------------------------------------------------------------
# Missing-source guard — MUST fire before any sips call so no asset is touched.
# ----------------------------------------------------------------------------
[ -f "$SRC" ] || { echo "error: source image not found: $SRC" >&2; exit 1; }

echo "source: $SRC"
echo "source dimensions:"
sips -g pixelWidth -g pixelHeight "$SRC"

# ----------------------------------------------------------------------------
# Scratch dir with cleanup trap.
# ----------------------------------------------------------------------------
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ----------------------------------------------------------------------------
# 1. Crop an offset square just inside the blue, then upscale once to the 1024
#    master PNG (forcing PNG format). --cropOffset is offsetY offsetX.
# ----------------------------------------------------------------------------
sips -s format png "$SRC" --out "$TMP/src.png" >/dev/null
sips -c "$CROP" "$CROP" --cropOffset "$OFF_Y" "$OFF_X" "$TMP/src.png" --out "$TMP/sq.png" >/dev/null
sips -z 1024 1024 -s format png "$TMP/sq.png" --out "$TMP/master.png" >/dev/null

# ----------------------------------------------------------------------------
# 2. Downscale-only from the master into the 7 distinct pixel sizes.
# ----------------------------------------------------------------------------
for px in 16 32 64 128 256 512 1024; do
  sips -z "$px" "$px" "$TMP/master.png" --out "$TMP/px_${px}.png" >/dev/null
done

# ----------------------------------------------------------------------------
# 3. Map the 7 pixel files to the 10 slot filenames (copies for shared sizes).
#    slot filename <- pixel size
# ----------------------------------------------------------------------------
# format: "<slot-filename> <pixel-size>"
SLOTS=(
  "icon_16.png 16"
  "icon_16_2x.png 32"
  "icon_32.png 32"
  "icon_32_2x.png 64"
  "icon_128.png 128"
  "icon_128_2x.png 256"
  "icon_256.png 256"
  "icon_256_2x.png 512"
  "icon_512.png 512"
  "icon_512_2x.png 1024"
)

for entry in "${SLOTS[@]}"; do
  name="${entry%% *}"
  px="${entry##* }"
  cp "$TMP/px_${px}.png" "$TMP/$name"
done

# ----------------------------------------------------------------------------
# 4. Verify all 10 slot files exist at exact pixel sizes in TMP before touching
#    the appiconset. Any deviation aborts, leaving $SET untouched.
# ----------------------------------------------------------------------------
dim() { sips -g "$1" "$2" | awk '/pixel/{print $2}'; }

for entry in "${SLOTS[@]}"; do
  name="${entry%% *}"
  px="${entry##* }"
  f="$TMP/$name"
  [ -f "$f" ] || { echo "error: expected generated file missing: $name" >&2; exit 1; }
  w="$(dim pixelWidth "$f")"
  h="$(dim pixelHeight "$f")"
  if [ "$w" != "$px" ] || [ "$h" != "$px" ]; then
    echo "error: $name is ${w}x${h}, expected ${px}x${px} — aborting, appiconset untouched" >&2
    exit 1
  fi
done

# ----------------------------------------------------------------------------
# 5. Atomic-ish publish: all checks passed, copy the 10 into the appiconset.
# ----------------------------------------------------------------------------
mkdir -p "$SET"
for entry in "${SLOTS[@]}"; do
  name="${entry%% *}"
  cp "$TMP/$name" "$SET/$name"
done

echo ""
echo "wrote 10 PNGs to $SET (crop: ${CROP}x${CROP} at offset x=${OFF_X},y=${OFF_Y}):"
for entry in "${SLOTS[@]}"; do
  name="${entry%% *}"
  px="${entry##* }"
  echo "  $name (${px}x${px})"
done
echo "done."
