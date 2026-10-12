#!/usr/bin/env bash
# SC-41: cross-compile the WHOLE headless engine (Hermes, ReactCommon, Fabric,
# SceneGraph, text) for android-arm64 and stage it, stripped, in
# engine/build/android-stage/bin. Not the P10 surface library
# (tools/android-build.sh): this is the rn-impeller executable the style gates
# run on a device through tools/android-run-engine.sh (adb shell, no APK).
#   rn-impeller, libimpeller.so (custom SDK: SC-32 text extensions),
#   libhermesvm.so, libc++_shared.so (all three C++ libs share one runtime).
# Headless rendering is EGL + GLES (HeadlessSurface, eglGetDisplay on android).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
: "${ANDROID_HOME:=$HOME/android-toolchain/sdk}"
NDK="$ANDROID_HOME/ndk/${NDK_VER:-27.1.12297006}"
TC="$NDK/build/cmake/android.toolchain.cmake"
BIN_TOOLS="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
API="${API:-29}"
SDK="${RNI_ANDROID_IMPELLER_SDK_DIR:-$ROOT/engine/third_party/impeller-sdk-custom-android}"
HB="$ROOT/engine/build-android-arm64-hermes"
EB="$ROOT/engine/build-android-arm64-engine"
OUT="$ROOT/engine/build/android-stage/bin"
JOBS="${JOBS:-$(nproc)}"
fail() { echo "engine-build-android: $*" >&2; exit 1; }
[ -f "$TC" ] || fail "NDK toolchain missing: $TC"
[ -f "$SDK/include/impeller.h" ] || fail "no android Impeller SDK at $SDK (RNI_SDK_TARGET=android-arm64 bash tools/impeller-sdk-custom-build.sh)"
[ -f engine/third_party/hermes-build/ImportHostCompilers.cmake ] || bash tools/hermes-build.sh
COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE="$TC"
        -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM="android-$API" -DANDROID_STL=c++_shared)

echo "== hermes (android-arm64, unicode-lite: no ICU, no JNI) =="
if [ ! -f "$HB/build.ninja" ]; then
  cmake -S engine/third_party/hermes -B "$HB" "${COMMON[@]}" \
    -DHERMES_ENABLE_DEBUGGER=ON -DHERMES_BUILD_SHARED_JSI=OFF -DHERMES_ENABLE_TEST_SUITE=OFF \
    -DHERMES_UNICODE_LITE=ON -DICU_FOUND=1 -DHERMES_ENABLE_INTL=OFF \
    -DIMPORT_HOST_COMPILERS="$ROOT/engine/third_party/hermes-build/ImportHostCompilers.cmake" \
    > "$HB.cfg.log" 2>&1 || { tail -20 "$HB.cfg.log" >&2; fail "hermes configure"; }
fi
cmake --build "$HB" -j"$JOBS" --target hermesvm > "$HB.log" 2>&1 || { grep -E 'error|FAILED' "$HB.log" | head -20 >&2; fail "hermes build"; }

echo "== engine (android-arm64, $SDK) =="
cmake -S engine -B "$EB" "${COMMON[@]}" -DRNI_WITH_WINDOW=OFF \
  -DIMPELLER_SDK="$SDK" -DHERMES_BUILD="$HB" > "$EB.cfg.log" 2>&1 \
  || { tail -20 "$EB.cfg.log" >&2; fail "engine configure"; }
# A killed build leaves zero-filled objects/binaries newer than their inputs; ninja never redoes them (SC-43).
[ -d "$EB" ] && find "$EB" \( -name '*.o' -o -name rn-impeller \) -type f | while read -r f; do
  [ "$(head -c4 "$f" | od -An -c | tr -d ' ')" = 177ELF ] || { echo "   removing non-ELF $f (interrupted build)"; rm -f "$f"; }
done
cmake --build "$EB" -j"$JOBS" --target rn-impeller > "$EB.log" 2>&1 \
  || { grep -E 'error:|FAILED:' "$EB.log" | head -20 >&2; fail "engine build"; }

echo "== stage $OUT =="
rm -rf "$OUT" && mkdir -p "$OUT"
STRIP="$BIN_TOOLS/bin/llvm-strip"
"$STRIP" -o "$OUT/rn-impeller" "$EB/rn-impeller"
"$STRIP" -o "$OUT/libimpeller.so" "$SDK/lib/libimpeller.so"
"$STRIP" -o "$OUT/libhermesvm.so" "$HB/lib/libhermesvm.so"
cp "$BIN_TOOLS/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$OUT/"
chmod 755 "$OUT"/*
file "$OUT/rn-impeller" | grep -q 'ARM aarch64' || fail "staged rn-impeller is not aarch64"
grep -q IMPELLER_RNI_TEXT_EXTENSIONS "$SDK/include/impeller.h" || echo "   WARN: $SDK is the stock SDK (no text extensions)"
ls -la "$OUT" | tail -n +2
echo "ENGINE_BUILD_ANDROID_OK $OUT"
