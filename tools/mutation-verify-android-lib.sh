#!/usr/bin/env bash
# Mutation verification for tools/ci-android-lib.sh.
#
# This gate guards failures that are INVISIBLE on this machine -- every one of
# them builds green here and only breaks on a device -- so it has to be seen
# RED before it means anything.
#
# Restore by cp and REBUILD between mutants (docs/STATE.md P9-A).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable-timeout.sh"  # portable timeout (mac fallback)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

JNI="engine/host/AndroidJni.cpp"
CML="engine/android/CMakeLists.txt"
GRADLE="android/build.gradle"
BUILDSH="tools/android-build.sh"
BACKUP="$(mktemp -d)"
cp "$JNI" "$BACKUP/AndroidJni.cpp"
cp "$CML" "$BACKUP/CMakeLists.txt"
cp "$GRADLE" "$BACKUP/build.gradle"
cp "$BUILDSH" "$BACKUP/android-build.sh"
restore() {
  cp "$BACKUP/AndroidJni.cpp" "$JNI"
  cp "$BACKUP/CMakeLists.txt" "$CML"
  cp "$BACKUP/build.gradle" "$GRADLE"
  cp "$BACKUP/android-build.sh" "$BUILDSH"
}
trap 'restore; rm -rf "$BACKUP"' EXIT

PASS=0
TOTAL=0

run_mutant() {
  local name="$1"
  TOTAL=$((TOTAL + 1))
  echo "--- mutant: $name ---"
  if timeout 600 bash tools/ci-android-lib.sh > /tmp/mal-gate.log 2>&1; then
    echo "  ⛔ NOT CAUGHT -- gate still passed"
  else
    echo "  caught:"
    grep -E "ANDROID_LIB_GATE_FAIL" /tmp/mal-gate.log | head -1 | sed 's/^/     /'
    PASS=$((PASS + 1))
  fi
  restore
}

echo "MUTATION_VERIFY_ANDROID_LIB_START"

# M1: rename a JNI export. Builds and links perfectly; JNI resolves by NAME at
# runtime, so this is an UnsatisfiedLinkError on the device and nothing else.
python3 - <<'PY'
p="engine/host/AndroidJni.cpp"; s=open(p).read()
s=s.replace("Java_com_reactnativeimpeller_ImpellerRenderer_nativeDrawTestFrame",
            "Java_com_reactnativeimpeller_ImpellerRenderer_nativeDrawTestFrameX",1)
open(p,"w").write(s)
PY
run_mutant "M1 a JNI symbol renamed (UnsatisfiedLinkError on device, green build)"

# M2: link libvulkan instead of dlopen'ing it. The library then fails to LOAD
# ENTIRELY on any device without Vulkan -- including all the parts that do not
# render -- rather than failing at one surface.
python3 - <<'PY'
p="engine/android/CMakeLists.txt"; s=open(p).read()
s=s.replace("  dl         # dlopen/dlsym for libvulkan.so",
            "  dl\n  vulkan  # MUTANT M2: hard link",1)
open(p,"w").write(s)
PY
run_mutant "M2 libvulkan linked instead of dlopen'd"

# M3: turn the module into an application. The whole point of the deliverable
# is that Impeller renders and the HOST app owns the APK.
python3 - <<'PY'
p="android/build.gradle"; s=open(p).read()
s=s.replace("    id 'com.android.library'",
            "    id 'com.android.application'  // MUTANT M3",1)
open(p,"w").write(s)
PY
run_mutant "M3 module declared as com.android.application"

# M4: point the build at the HOST Impeller SDK. It compiles -- the header is
# byte-identical across platforms -- and produces a library that cannot load on
# a phone.
#
# ⚠️ MUTATE tools/android-build.sh, NOT engine/android/CMakeLists.txt. The
# first attempt changed the CMakeLists default and was NOT caught: IMPELLER_SDK
# is a CACHE variable, so the existing CMakeCache.txt kept the old (correct)
# path and the build stayed green. The build script is now the single place the
# SDK path is decided, which is what makes this mutant meaningful.
python3 - <<'PY'
p="tools/android-build.sh"; s=open(p).read()
s=s.replace('SDK_DIR="engine/third_party/impeller-sdk-android"',
            'SDK_DIR="engine/third_party/impeller-sdk"  # MUTANT M4: host SDK',1)
open(p,"w").write(s)
PY
run_mutant "M4 built against the x86_64 host SDK"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_ANDROID_LIB_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_ANDROID_LIB_FAIL ($PASS/$TOTAL)"
  exit 1
fi
