#!/usr/bin/env bash
# iOS: configure + build the iOS branch of engine/CMakeLists.txt (engine/ios/RniIos.cmake)
# for the iOS Simulator (default) or a device, with Ninja. The product is
# engine/build-ios-<target>/librni_ios_all.a: the engine (rni_ios_engine,
# engine/ios/RniIosEngine.cmake) and every static library it needs, merged, for
# an iOS host to link with libimpeller.a and hermesvm.framework.
#   bash tools/engine-build-ios.sh [simulator|device]   (on linux: RNI_MAC_HOST=<ssh host> runs it on a Mac)
# Env: RNI_IOS_TARGET_LIB  the target to build (default rni_ios_all;
#                          rni_ios_platform builds only the surface primitives)
# Inputs, staged on the Mac first:
#   tools/sdk-fetch-ios.sh     engine/third_party/impeller-sdk-ios-simulator-arm64
#   tools/hermes-build-ios.sh  engine/third_party/hermes-ios
#   engine/rn npm install      ReactCommon sources
# FetchContent sources (boost, folly, glog, fmt, ...) are cached in
# ~/Library/Caches/rni-ios-ci/fetchcontent, so a fresh build dir does not
# download them again. device needs engine/third_party/impeller-sdk-ios-arm64,
# which nothing builds yet: configure says so by name.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(uname -s)" != Darwin ]; then
  [ -n "${RNI_MAC_HOST:-}" ] || { echo "engine-build-ios: macOS only (from linux: RNI_MAC_HOST=<ssh host>)" >&2; exit 2; }
  RNI_MAC_TREE="${RNI_MAC_TREE:-rni-ios}" RNI_MAC_ENV="RNI_IOS_TARGET_LIB RNI_IOS_BUILD_DIR" \
    exec bash "$ROOT/tools/mac-run.sh" bash tools/engine-build-ios.sh "$@"
fi
cd "$ROOT"
TARGET="${1:-simulator}"
case "$TARGET" in
  simulator) SYSROOT=iphonesimulator ;;
  device) SYSROOT=iphoneos ;;
  *) echo "usage: $0 [simulator|device]" >&2; exit 64 ;;
esac
BUILD="${RNI_IOS_BUILD_DIR:-$ROOT/engine/build-ios-$TARGET}"
LIBTARGET="${RNI_IOS_TARGET_LIB:-rni_ios_all}"
FC="$HOME/Library/Caches/rni-ios-ci/fetchcontent"
export PATH="/opt/homebrew/bin:$PATH"   # cmake, ninja
# A build dir from the earlier Xcode-generator script cannot be reused by Ninja.
if [ -f "$BUILD/CMakeCache.txt" ] && ! grep -q '^CMAKE_GENERATOR:INTERNAL=Ninja$' "$BUILD/CMakeCache.txt"; then
  rm -rf "$BUILD"
fi
mkdir -p "$FC"
t0=$SECONDS
cmake -S engine -B "$BUILD" -G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SYSROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.1 -DCMAKE_BUILD_TYPE=Release \
  -DFETCHCONTENT_BASE_DIR="$FC" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 > "$BUILD.configure.log" 2>&1 \
  || { grep -A6 -m3 'CMake Error' "$BUILD.configure.log"; echo "ENGINE_BUILD_IOS_FAIL (configure)"; exit 1; }
grep 'rni-ios:' "$BUILD.configure.log"
echo "engine-build-ios: configured in $((SECONDS - t0))s; building $LIBTARGET (log $BUILD.build.log)"
if ! cmake --build "$BUILD" --target "$LIBTARGET" -- -k 0 > "$BUILD.build.log" 2>&1; then
  echo "engine-build-ios: $(grep -c 'error:' "$BUILD.build.log") error lines; first ones:"
  grep -m20 -E 'error:|undefined symbol|Undefined symbols' "$BUILD.build.log"
  echo "ENGINE_BUILD_IOS_FAIL (build)"
  exit 1
fi
case "$LIBTARGET" in
  rni_ios_all) LIB="$BUILD/librni_ios_all.a" ;;
  *) LIB="$(find "$BUILD" -name "lib$LIBTARGET.a" | head -1)" ;;
esac
[ -f "$LIB" ] || { echo "ENGINE_BUILD_IOS_FAIL (no $LIB)"; exit 1; }
echo "engine-build-ios: $TARGET in $((SECONDS - t0))s: ${LIB#"$ROOT"/} ($(du -h "$LIB" | cut -f1), $(lipo -archs "$LIB"))"
echo "ENGINE_BUILD_IOS_OK $LIB"
