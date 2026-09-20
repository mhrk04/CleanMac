#!/bin/zsh
# SCAN-ONLY read-only harness build+run.
#
# Mirrors .verify/run-tests.sh steps 1-2 (strip #Preview, compile CleanMac into
# a dylib with the Command Line Tools toolchain) then compiles scan-only/main.swift
# linked against the CleanMac dylib and runs it.
#
# This is strictly READ-ONLY: the harness never deletes or moves files. It only
# runs the real ScannerEngine and prints what a clean WOULD target.
#
# Usage: bash .verify/scan-only/run.sh
#    or: zsh  .verify/scan-only/run.sh
set -e

# Resolve repo root (this script lives at <root>/.verify/scan-only/run.sh).
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

# Intermediate build artefacts stay out of the source tree.
BUILD="${CLEANMAC_SCANONLY_BUILD:-${TMPDIR:-/tmp}/cleanmac-scanonly-build}"
SDK=$(xcrun --show-sdk-path)
TARGET=arm64-apple-macos14.0
COMMON=(-sdk "$SDK" -target "$TARGET" -strict-concurrency=complete)

# Rules directory passed to the harness (the real bundled YAML).
SCAN_RULES_DIR="$ROOT/CleanMac/Resources/Rules"

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> 1/3 strip #Preview macros"
python3 "$ROOT/.verify/strippreview.py" "$ROOT/CleanMac" "$BUILD/src/CleanMac"

echo "==> 2/3 build CleanMac library"
(cd "$BUILD/src" && swiftc -emit-library -emit-module \
  -module-name CleanMac \
  -emit-module-path "$BUILD/CleanMac.swiftmodule" \
  -o "$BUILD/libCleanMac.dylib" \
  "${COMMON[@]}" \
  $(find CleanMac -name '*.swift' | sort))

echo "==> 3/3 build & run scan-only harness"
cp "$HERE/main.swift" "$BUILD/main.swift"
swiftc -o "$BUILD/cleanmac-scan-only" \
  -module-name CleanMacScanOnly \
  "${COMMON[@]}" \
  -I "$BUILD" -L "$BUILD" -lCleanMac \
  -Xlinker -rpath -Xlinker "$BUILD" \
  "$BUILD/main.swift"

echo
# Pass the rules dir via env. SCAN_ONLY_RULE_IDS (optional) can restrict the run.
SCAN_RULES_DIR="$SCAN_RULES_DIR" "$BUILD/cleanmac-scan-only"
