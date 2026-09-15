#!/bin/zsh
# Build and run the CleanMacTests suite without Xcode.
#
# The Command Line Tools toolchain has no XCTest.framework and no PreviewsMacros
# plugin, so this script:
#   1. copies CleanMac/ and strips `#Preview` blocks,
#   2. compiles it into a dynamic library with `-enable-testing`,
#   3. compiles the functional XCTest stand-in in .verify/XCTest.swift,
#   4. generates a runner that calls every `func testX()` it finds,
#   5. links and executes the whole thing.
#
# Usage: .verify/run-tests.sh
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Intermediate build artefacts stay out of the source tree.
BUILD="${CLEANMAC_VERIFY_BUILD:-${TMPDIR:-/tmp}/cleanmac-verify-build}"
SDK=$(xcrun --show-sdk-path)
TARGET=arm64-apple-macos14.0
COMMON=(-sdk "$SDK" -target "$TARGET" -strict-concurrency=complete)

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> 1/5 strip #Preview macros"
python3 "$ROOT/.verify/strippreview.py" "$ROOT/CleanMac" "$BUILD/src/CleanMac"

echo "==> 2/5 build CleanMac library (-enable-testing)"
(cd "$BUILD/src" && swiftc -emit-library -emit-module \
  -module-name CleanMac -enable-testing \
  -emit-module-path "$BUILD/CleanMac.swiftmodule" \
  -o "$BUILD/libCleanMac.dylib" \
  "${COMMON[@]}" \
  $(find CleanMac -name '*.swift' | sort))

echo "==> 3/5 build XCTest stand-in"
swiftc -emit-library -emit-module \
  -module-name XCTest \
  -emit-module-path "$BUILD/XCTest.swiftmodule" \
  -o "$BUILD/libXCTestShim.dylib" \
  "${COMMON[@]}" \
  "$ROOT/.verify/XCTest.swift"

echo "==> 4/5 generate runner"
python3 "$ROOT/.verify/genrunner.py" "$ROOT/CleanMacTests" "$BUILD/Runner.swift"
cp "$ROOT/.verify/main.swift" "$BUILD/main.swift"

echo "==> 5/5 build & run tests"
swiftc -o "$BUILD/cleanmac-tests" \
  -module-name CleanMacTestsRunner \
  "${COMMON[@]}" \
  -I "$BUILD" -L "$BUILD" -lCleanMac -lXCTestShim \
  -Xlinker -rpath -Xlinker "$BUILD" \
  $(find "$ROOT/CleanMacTests" -name '*.swift' | sort) \
  "$BUILD/Runner.swift" "$BUILD/main.swift"

echo
"$BUILD/cleanmac-tests"
