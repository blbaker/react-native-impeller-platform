#!/usr/bin/env bash
# Build the throwaway probe APK that hosts the render library on a device.
#
# ⛔ THE PROBE IS NOT THE DELIVERABLE. The library (android/) is a
# com.android.library and must stay one; this app module exists only to prove
# the render path on hardware, exactly as HostApp v4's own app will host it.
#
# ⛔ NO GRADLE, ON PURPOSE. This box has none, and installing a whole build
# system to produce a two-class throwaway APK is a large dependency for a
# small job. aapt2 + d8 + apksigner all ship in the Android SDK's build-tools
# and do the entire job in four commands, which also makes every step's
# failure legible instead of buried in a Gradle stack trace.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ANDROID_HOME:=$HOME/android-toolchain/sdk}"
: "${JAVA_HOME:=$HOME/android-toolchain/jdk17}"
BT_VER="${BT_VER:-35.0.0}"
PLATFORM_VER="${PLATFORM_VER:-android-35}"

BT="$ANDROID_HOME/build-tools/$BT_VER"
ANDROID_JAR="$ANDROID_HOME/platforms/$PLATFORM_VER/android.jar"
export PATH="$JAVA_HOME/bin:$PATH"

[ -d "$BT" ] || { echo "build-tools $BT_VER not found at $BT" >&2; exit 1; }
[ -f "$ANDROID_JAR" ] || { echo "android.jar not found at $ANDROID_JAR" >&2; exit 1; }

fail() { echo "PROBE_BUILD_FAIL: $*" >&2; exit 1; }

echo "== 1. cross-compile the native library =="
bash tools/android-build.sh > /tmp/probe-native.log 2>&1 \
  || { tail -20 /tmp/probe-native.log >&2; fail "native build"; }

OUT="probe/build-out"
rm -rf "$OUT"
mkdir -p "$OUT/lib/arm64-v8a" "$OUT/classes" "$OUT/dex"

echo "== 2. stage the .so files the APK will package =="
cp engine/build-android-arm64-v8a/libreactnativeimpeller.so "$OUT/lib/arm64-v8a/"
# ⚠️ Ship the STRIPPED Impeller. sdk-fetch.sh already ran llvm-strip over it
# (228 MB -> 6.9 MB); packaging the unstripped copy would put a quarter of a
# gigabyte of debug symbols into the APK.
cp engine/third_party/impeller-sdk-android/lib/libimpeller.so "$OUT/lib/arm64-v8a/"
ls -la "$OUT/lib/arm64-v8a" | tail -2 | sed 's/^/   /'

echo "== 3. compile java (library sources + the probe Activity) =="
find android/src/main/java probe/android/src/main/java -name "*.java" > "$OUT/sources.txt"
# ⚠️ `-bootclasspath` is REJECTED by JDK 17 when paired with `-target 17`
# ("option --boot-class-path not allowed with target 17"). android.jar goes on
# the ordinary classpath instead; d8 does the real Android-API validation.
javac -source 17 -target 17 -nowarn \
      -classpath "$ANDROID_JAR" -d "$OUT/classes" \
      @"$OUT/sources.txt" 2> "$OUT/javac.log" \
  || { cat "$OUT/javac.log" >&2; fail "javac"; }

echo "== 4. dex =="
"$BT/d8" --release --lib "$ANDROID_JAR" --output "$OUT/dex" \
  $(find "$OUT/classes" -name "*.class") > /dev/null 2>&1 || fail "d8"

echo "== 5. package + sign =="
"$BT/aapt2" link -I "$ANDROID_JAR" \
  --manifest probe/android/src/main/AndroidManifest.xml \
  --min-sdk-version 29 --target-sdk-version 34 \
  -o "$OUT/base.apk" > /dev/null 2>&1 || fail "aapt2 link"

# aapt2 emits the resource/manifest container; the dex and the .so files are
# added as ordinary zip entries.
#
# ⚠️ `zip` IS NOT INSTALLED on this box (neither is `unzip` -- sdk-fetch.sh hit
# the same gap and uses python3 for the same reason). python3's zipfile is
# always present and lets the lib/<abi>/ paths be written exactly, which the
# loader requires; a flattened entry is silently ignored at runtime.
python3 - "$OUT" <<'PY' || fail "packaging"
import os, sys, zipfile
out = sys.argv[1]
apk = os.path.join(out, "base.apk")
with zipfile.ZipFile(apk, "a", zipfile.ZIP_DEFLATED) as z:
    z.write(os.path.join(out, "dex", "classes.dex"), "classes.dex")
    libdir = os.path.join(out, "lib")
    for root, _, files in os.walk(libdir):
        for f in files:
            full = os.path.join(root, f)
            arc = os.path.relpath(full, out)   # lib/arm64-v8a/foo.so
            # ⛔ .so files must be STORED, not deflated, when extractNativeLibs
            # is false on modern Android; storing is always safe.
            zi = zipfile.ZipInfo(arc)
            zi.compress_type = zipfile.ZIP_STORED
            with open(full, "rb") as fh:
                z.writestr(zi, fh.read())
print("   packaged classes.dex + native libs")
PY

KEYSTORE="$OUT/probe.keystore"
keytool -genkeypair -keystore "$KEYSTORE" -alias probe -storepass android \
        -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=rn-impeller probe" > /dev/null 2>&1 || fail "keytool"

"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android \
  --key-pass pass:android --out "$OUT/probe.apk" "$OUT/base.apk" \
  > /dev/null 2>&1 || fail "apksigner"

echo "PROBE_BUILD_OK $OUT/probe.apk ($(stat -c%s "$OUT/probe.apk") bytes)"
