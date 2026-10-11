#!/usr/bin/env bash
# Cross-compile the Android render library (arm64-v8a).
#
# Produces libreactnativeimpeller.so + the prebuilt libimpeller.so, which a
# HOST APP packages. This script does not build an APK and never will -- the
# app that embeds this owns its own Gradle build.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ANDROID_HOME:=$HOME/android-toolchain/sdk}"
NDK_VER="${NDK_VER:-27.1.12297006}"
NDK="$ANDROID_HOME/ndk/$NDK_VER"
ABI="${ABI:-arm64-v8a}"
API="${API:-29}"   # Impeller's Vulkan path targets API 29+; below that is GLES.

[ -d "$NDK" ] || { echo "NDK not found at $NDK" >&2; exit 1; }

TOOLCHAIN="$NDK/build/cmake/android.toolchain.cmake"
[ -f "$TOOLCHAIN" ] || { echo "toolchain file missing: $TOOLCHAIN" >&2; exit 1; }

SDK_DIR="engine/third_party/impeller-sdk-android"
# SC-35: RNI_ANDROID_IMPELLER_SDK_DIR=engine/third_party/impeller-sdk-custom-android
# builds against the custom SDK (SC-33/34 text features). Opt-in: its lib is unstripped.
SDK_DIR="${RNI_ANDROID_IMPELLER_SDK_DIR:-$SDK_DIR}"
if [ ! -f "$SDK_DIR/include/impeller.h" ]; then
  echo "== fetching the android-arm64 Impeller SDK =="
  RNI_SDK_PLATFORM=android-arm64 bash tools/sdk-fetch.sh "$SDK_DIR"
fi

# ⛔ PASS IMPELLER_SDK EXPLICITLY, AND RECONFIGURE WHEN IT CHANGES.
#
# IMPELLER_SDK is a CACHE variable, so once CMakeCache.txt exists, editing its
# default in CMakeLists.txt has NO effect -- the cached value wins silently.
# That made a mutant pointing the build at the x86_64 HOST SDK produce a
# perfectly good arm64 library, because the cache still held the Android path.
# Passing it on the command line every time makes the intent explicit and the
# cache irrelevant.
SDK_ABS="$(cd "$SDK_DIR" && pwd)"

BUILD="engine/build-android-$ABI"
# A stale cache pointing at a different SDK is worse than a slow reconfigure.
if [ -f "$BUILD/CMakeCache.txt" ] && \
   ! grep -q "IMPELLER_SDK:PATH=$SDK_ABS\$" "$BUILD/CMakeCache.txt"; then
  echo "== SDK path changed; wiping the stale CMake cache =="
  rm -rf "$BUILD"
fi

cmake -S engine/android -B "$BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="android-$API" \
  -DIMPELLER_SDK="$SDK_ABS" \
  -DCMAKE_BUILD_TYPE=Release \
  > /tmp/android-configure.log 2>&1 || {
    tail -25 /tmp/android-configure.log >&2
    echo "ANDROID_BUILD_FAIL: cmake configure" >&2; exit 1; }

cmake --build "$BUILD" -j"$(nproc)" > /tmp/android-build.log 2>&1 || {
  grep -E "error:" /tmp/android-build.log | head -20 >&2
  echo "ANDROID_BUILD_FAIL: compile" >&2; exit 1; }

OUT="$BUILD/libreactnativeimpeller.so"
[ -f "$OUT" ] || { echo "ANDROID_BUILD_FAIL: no .so produced" >&2; exit 1; }

echo "ANDROID_BUILD_OK $OUT ($(stat -c%s "$OUT") bytes)"
file "$OUT"
