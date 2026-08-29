#!/usr/bin/env bash
# P10-A gate — the Android RENDER LIBRARY builds and is shaped like a library.
#
# ⛔ WHAT THIS ASSERTS, AND WHY EACH ONE IS A REAL FAILURE MODE
#
#   1. arm64 ELF          a host-arch .so compiles and links happily on this
#                         box and fails only on the device
#   2. JNI symbols        C++ and Java are matched by NAME at RUNTIME; a typo
#                         or a namespace change builds green and throws
#                         UnsatisfiedLinkError on the device
#   3. NO libvulkan in NEEDED
#                         linking it makes the WHOLE library fail to load on a
#                         device without Vulkan, instead of failing at one
#                         surface where the caller can fall back
#   4. libimpeller present and stripped
#                         the unstripped SDK library is 228 MB; shipping it
#                         would add a quarter of a gigabyte to the host's APK
#   5. no Activity/APK    the deliverable is a renderer the app embeds. An
#                         `applicationId` or a launcher intent here means
#                         someone has misunderstood the scope
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${ANDROID_HOME:=$HOME/android-toolchain/sdk}"
NDK_VER="${NDK_VER:-27.1.12297006}"
TOOLS="$ANDROID_HOME/ndk/$NDK_VER/toolchains/llvm/prebuilt/linux-x86_64/bin"
NM="$TOOLS/llvm-nm"
READELF="$TOOLS/llvm-readelf"

fail() { echo "ANDROID_LIB_GATE_FAIL: $*" >&2; exit 1; }

[ -x "$NM" ] || fail "NDK llvm-nm not found at $NM"

echo "== 1. build =="
bash tools/android-build.sh > /tmp/android-gate-build.log 2>&1 \
  || { tail -20 /tmp/android-gate-build.log >&2; fail "the library did not build"; }

SO="engine/build-android-arm64-v8a/libreactnativeimpeller.so"
[ -f "$SO" ] || fail "no libreactnativeimpeller.so produced"

echo "== 2. it is a real arm64 object, not a host build =="
ARCH="$(file -b "$SO")"
echo "   $ARCH"
case "$ARCH" in
  *"ARM aarch64"*) ;;
  *) fail "not an arm64 ELF: $ARCH -- a host-arch build links fine here and fails only on the device" ;;
esac

echo "== 3. every JNI entry point Java declares is exported =="
# ⛔ JNI binds by NAME at runtime. These five strings must match
# ImpellerRenderer.java exactly; nothing checks that at compile time.
EXPECTED="nativeCreate nativeDestroy nativeAttachSurface nativeDetachSurface nativeDrawTestFrame"
SYMS="$($NM -D "$SO" | grep " T Java_" || true)"
echo "$SYMS" | sed 's/^/   /'
# ⛔ ANCHOR AT END-OF-LINE. A bare grep for "..._nativeDrawTestFrame" also
# matches "..._nativeDrawTestFrameX" -- so renaming a symbol by appending a
# character passed this check, which is exactly the typo class it exists to
# catch. Verified: the mutant built, exported ...FrameX, and the gate went
# green. The symbol is the last field of llvm-nm output, hence '$'.
for fn in $EXPECTED; do
  echo "$SYMS" | grep -qE "Java_com_reactnativeimpeller_ImpellerRenderer_${fn}\$" \
    || fail "JNI symbol missing: $fn -- Java would throw UnsatisfiedLinkError on the device while the build stays green"
done
# And the reverse direction: a native declared in Java but absent here.
for fn in $(grep -oP 'private static native \w+ \K\w+' \
            android/src/main/java/com/reactnativeimpeller/ImpellerRenderer.java); do
  echo "$SYMS" | grep -qE "ImpellerRenderer_${fn}\$" \
    || fail "Java declares native '$fn' with no matching exported symbol"
done
# Nothing EXTRA either: a stray Java_ export means a renamed symbol left its
# old name behind, or a second copy is being built.
SYM_COUNT="$(echo "$SYMS" | grep -c " T Java_" || true)"
[ "$SYM_COUNT" -eq 5 ] \
  || fail "expected exactly 5 JNI exports, found $SYM_COUNT -- a renamed or duplicated native"

echo "== 4. libvulkan is NOT a link-time dependency =="
NEEDED="$($READELF -d "$SO" | grep NEEDED || true)"
echo "$NEEDED" | sed 's/^/   /'
if echo "$NEEDED" | grep -q "libvulkan"; then
  fail "libvulkan.so is in NEEDED. The library must dlopen it, or the WHOLE .so fails to load on a device without Vulkan instead of failing at one surface"
fi
echo "$NEEDED" | grep -q "libimpeller.so" \
  || fail "libimpeller.so is not linked -- nothing would render"

echo "== 5. the shipped libimpeller is stripped =="
IMP="engine/third_party/impeller-sdk-android/lib/libimpeller.so"
[ -f "$IMP" ] || fail "android Impeller SDK missing at $IMP"
IMP_SIZE="$(stat -c%s "$IMP")"
echo "   libimpeller.so = $IMP_SIZE bytes"
[ "$IMP_SIZE" -lt 50000000 ] \
  || fail "libimpeller.so is ${IMP_SIZE} bytes -- unstripped (the SDK ships 228 MB of debug symbols; that lands in the host app's APK)"
file -b "$IMP" | grep -q "ARM aarch64" \
  || fail "the shipped libimpeller.so is not arm64"

echo "== 6. this is a LIBRARY, not an app =="
GRADLE="android/build.gradle"
[ -f "$GRADLE" ] || fail "android/build.gradle missing"
grep -q "com.android.library" "$GRADLE" \
  || fail "android/build.gradle does not apply com.android.library"
# ⛔ MATCH THE PLUGIN ID EXACTLY, WITH ITS QUOTES.
#
# A bare `grep -q "com.android.application"` matches the string
# "com.android.library" is NOT a superstring of -- but it DOES match this
# file's own explanatory comment ("NEVER com.android.application"), so the
# gate failed on correct code. Anchor on the actual plugin declaration.
if grep -qE "id +['\"]com\.android\.application['\"]" "$GRADLE"; then
  fail "android/build.gradle applies com.android.application -- this module must never produce an APK; the host app owns that"
fi
if grep -qE "^\s*applicationId" "$GRADLE"; then
  fail "android/build.gradle sets an applicationId -- a library has no application identity"
fi
if find android -name AndroidManifest.xml 2>/dev/null \
   | xargs grep -l "android.intent.action.MAIN" 2>/dev/null | grep -q .; then
  fail "a launcher Activity is declared -- the deliverable is a renderer the host app embeds, not an app"
fi

echo "ANDROID_LIB_GATE_PASS (arm64 .so, 5 JNI symbols, vulkan dlopen'd, libimpeller $IMP_SIZE bytes, library-not-app)"
