#!/usr/bin/env bash
# iOS Phase 1 (Task 1.6): configure + build the iOS branch of engine/CMakeLists.txt
# (engine/ios/RniIos.cmake): the rni_ios_platform static library for the iOS
# Simulator (default) or a device. Modeled on tools/engine-build.sh, minus the
# desktop staging: the product is a library the iOS host (Phase 3) links.
#   bash tools/engine-build-ios.sh [simulator|device]   (on linux: RNI_MAC_HOST=<ssh host> runs it on a Mac)
# Inputs, staged on the Mac first:
#   tools/sdk-fetch-ios.sh     engine/third_party/impeller-sdk-ios-simulator-arm64
#   tools/hermes-build-ios.sh  engine/third_party/hermes-ios
# device needs engine/third_party/impeller-sdk-ios-arm64, which nothing builds
# yet (the first iOS milestone is simulator-only): configure says so by name.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(uname -s)" != Darwin ]; then
  [ -n "${RNI_MAC_HOST:-}" ] || { echo "engine-build-ios: macOS only (from linux: RNI_MAC_HOST=<ssh host>)" >&2; exit 2; }
  RNI_MAC_TREE="${RNI_MAC_TREE:-rni-ios}" exec bash "$ROOT/tools/mac-run.sh" bash tools/engine-build-ios.sh "$@"
fi
cd "$ROOT"
TARGET="${1:-simulator}"
case "$TARGET" in
  simulator) SYSROOT=iphonesimulator ;;
  device) SYSROOT=iphoneos ;;
  *) echo "usage: $0 [simulator|device]" >&2; exit 64 ;;
esac
BUILD="${RNI_IOS_BUILD_DIR:-$ROOT/engine/build-ios-$TARGET}"
export PATH="/opt/homebrew/bin:$PATH"   # cmake
t0=$SECONDS
cmake -S engine -B "$BUILD" -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SYSROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.1 > "$BUILD.configure.log" 2>&1 \
  || { grep -A3 -m3 'CMake Error' "$BUILD.configure.log"; echo "ENGINE_BUILD_IOS_FAIL (configure)"; exit 1; }
grep 'rni-ios:' "$BUILD.configure.log"
cmake --build "$BUILD" --config Release --target rni_ios_platform -- -quiet > "$BUILD.build.log" 2>&1 \
  || { grep -m10 -E 'error:|BUILD FAILED' "$BUILD.build.log"; echo "ENGINE_BUILD_IOS_FAIL (build)"; exit 1; }
LIB="$(find "$BUILD" -name librni_ios_platform.a -path '*Release*' | head -1)"
[ -f "$LIB" ] || { echo "ENGINE_BUILD_IOS_FAIL (no librni_ios_platform.a under $BUILD)"; exit 1; }
echo "engine-build-ios: $TARGET in $((SECONDS - t0))s: ${LIB#"$ROOT"/} ($(du -h "$LIB" | cut -f1), $(lipo -archs "$LIB"))"
echo "ENGINE_BUILD_IOS_OK $LIB"
