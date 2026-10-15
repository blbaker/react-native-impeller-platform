#!/usr/bin/env bash
# FP-24: build the swapchain probe APK (tools/android-swapchain-probe), a
# code-less NativeActivity test harness around engine/host/AndroidVkSurface.cpp.
# This is a GATE fixture, not the library's deliverable (android/ never builds an APK).
# No Gradle: NDK CMake -> aapt2 link -> add stripped libs -> zipalign -> apksigner.
#   bash tools/android-swapchain-probe-build.sh [out.apk]
# Env: RNI_ANDROID_IMPELLER_SDK_DIR (default: the -parity-android SDK, patch 0004).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT_APK="${1:-$ROOT/engine/build-fp24-probe/fp24probe.apk}"
: "${ANDROID_HOME:=$HOME/android-toolchain/sdk}"
NDK="$ANDROID_HOME/ndk/${NDK_VER:-27.1.12297006}"
BT="$ANDROID_HOME/build-tools/35.0.0"
JAR="$ANDROID_HOME/platforms/android-35/android.jar"
STRIP="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
SDK="${RNI_ANDROID_IMPELLER_SDK_DIR:-engine/third_party/impeller-sdk-custom-parity-android}"
die() { echo "FP24_PROBE_BUILD_FAIL: $*" >&2; exit 1; }
[ -f "$SDK/include/impeller.h" ] || die "no Impeller SDK at $SDK (RNI_SDK_TARGET=android-arm64 bash tools/impeller-sdk-custom-build.sh $SDK)"
for t in "$BT/aapt2" "$BT/zipalign" "$BT/apksigner" "$JAR" "$STRIP"; do [ -e "$t" ] || die "missing $t"; done
KS="$HOME/.android/debug.keystore"
[ -f "$KS" ] || die "no debug keystore at $KS"
SDK_ABS="$(cd "$SDK" && pwd)"
B="$ROOT/engine/build-fp24-probe"
mkdir -p "$B"
if [ -f "$B/cmake/CMakeCache.txt" ] && ! grep -q "IMPELLER_SDK:UNINITIALIZED=$SDK_ABS\$" "$B/cmake/CMakeCache.txt"; then
  rm -rf "$B/cmake"   # IMPELLER_SDK is cached; a changed SDK needs a fresh configure
fi
cmake -S tools/android-swapchain-probe -B "$B/cmake" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-29 -DCMAKE_BUILD_TYPE=Release \
  -DIMPELLER_SDK="$SDK_ABS" > "$B/configure.log" 2>&1 || { tail -15 "$B/configure.log" >&2; die "cmake configure"; }
cmake --build "$B/cmake" > "$B/build.log" 2>&1 || { grep -E "error" "$B/build.log" | head -15 >&2; die "compile"; }

rm -rf "$B/apk"; mkdir -p "$B/apk/lib/arm64-v8a"
cp "$B/cmake/libfp24probe.so" "$B/apk/lib/arm64-v8a/"
# The SDK's libimpeller.so is 228 MB unstripped; 7 MB stripped.
if [ ! -f "$B/libimpeller.stripped.so" ] || [ "$SDK_ABS/lib/libimpeller.so" -nt "$B/libimpeller.stripped.so" ]; then
  "$STRIP" --strip-unneeded -o "$B/libimpeller.stripped.so" "$SDK_ABS/lib/libimpeller.so"
fi
cp "$B/libimpeller.stripped.so" "$B/apk/lib/arm64-v8a/libimpeller.so"
"$BT/aapt2" link -o "$B/base.apk" --manifest tools/android-swapchain-probe/AndroidManifest.xml \
  -I "$JAR" --debug-mode > "$B/aapt2.log" 2>&1 || { cat "$B/aapt2.log" >&2; die "aapt2 link"; }
python3 - "$B/base.apk" "$B/apk" <<'PY'  # no `zip` on this box; libs stored uncompressed
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "a", zipfile.ZIP_STORED) as z:
    for d, _, fs in os.walk(os.path.join(sys.argv[2], "lib")):
        for f in fs:
            p = os.path.join(d, f); z.write(p, os.path.relpath(p, sys.argv[2]))
PY
"$BT/zipalign" -f -p 4 "$B/base.apk" "$B/aligned.apk"
mkdir -p "$(dirname "$OUT_APK")"
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$OUT_APK" "$B/aligned.apk" > "$B/sign.log" 2>&1 || { cat "$B/sign.log" >&2; die "apksigner"; }
echo "FP24_PROBE_BUILD_OK $OUT_APK ($(stat -c%s "$OUT_APK") bytes, sdk=$SDK)"
