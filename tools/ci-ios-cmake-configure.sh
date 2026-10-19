#!/usr/bin/env bash
# iOS Phase 1 / Task 1.6 gate: the iOS branch of engine/CMakeLists.txt
# configures and builds. Runs on the Mac (re-execs there from linux).
#   cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator ...
# Arms (each failure prints `IOS_CMAKE_GATE FAIL <arm>: ...`):
#   C  configure exits 0 with no CMake Error / FATAL_ERROR, and reports the
#      iOS Impeller SDK and the Hermes xcframework it resolved (rni-ios: lines)
#   N  no ANGLE, no GLFW, no GLES anywhere in the generated build (CMakeCache
#      and the Xcode project): iOS is Metal only
#   B  rni_ios_platform builds: an arm64 static library for the iOS Simulator
#      holding the Phase 1 symbols (MetalSurfaceIOS, DisplayLinkIOS, the GPU
#      observers, ReadAccessibilitySettings, InstallIOSClipboard)
# Pass line: IOS_CMAKE_CONFIGURE_PASS (lib=<size>). Mutants:
# tools/mutation-verify-ios-cmake-configure.sh (a missing Hermes xcframework or
# Impeller SDK must fail configure with ITS named error).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
ios_begin cmake
FAILS=()
bad() { echo "IOS_CMAKE_GATE FAIL $1: $2"; FAILS+=("$1"); }
export PATH="/opt/homebrew/bin:$PATH"   # cmake
B="$IOS_WORK/build"

cmake -S engine -B "$B" -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.1 > "$IOS_WORK/configure.log" 2>&1
RC=$?
grep -E 'rni-ios:|CMake Error|FATAL' "$IOS_WORK/configure.log"
ios_keep "$IOS_WORK/configure.log"
if [ "$RC" != 0 ] || grep -qE 'CMake Error|FATAL_ERROR' "$IOS_WORK/configure.log"; then
  bad C "configure rc=$RC: $(grep -m1 -A2 'CMake Error' "$IOS_WORK/configure.log" | tr '\n' ' ')"
  echo "IOS_CMAKE_CONFIGURE_FAIL (${FAILS[*]})"
  exit 1
fi
grep -q 'rni-ios: impeller_sdk=.*impeller-sdk-ios-simulator-arm64' "$IOS_WORK/configure.log" \
  || bad C "no iOS Simulator Impeller SDK reported"
grep -q 'rni-ios: hermes=.*hermesvm.xcframework' "$IOS_WORK/configure.log" || bad C "no Hermes xcframework reported"

echo "== N: Metal only =="
HITS=$(grep -ilE 'angle|glfw|libGLESv2|libEGL' "$B/CMakeCache.txt" "$B"/*.xcodeproj/project.pbxproj 2> /dev/null || true)
[ -z "$HITS" ] || bad N "ANGLE/GLFW/GLES referenced in: $HITS"
echo "angle/glfw/gles references: ${HITS:-none}"

echo "== B: build rni_ios_platform =="
if cmake --build "$B" --config Release --target rni_ios_platform -- -quiet > "$IOS_WORK/build.log" 2>&1; then
  LIB="$(find "$B" -name librni_ios_platform.a | head -1)"
  nm -gUC "$LIB" > "$IOS_WORK/nm.txt" 2> /dev/null || true
  MISSING=()
  for sym in 'rni::MetalSurfaceIOS::Attach' 'rni::DisplayLinkIOS::DisplayLinkIOS' \
    'rni::gpu::InstallGpuAvailabilityObservers' 'rni::ReadAccessibilitySettings' \
    'rni::InstallIOSClipboard' 'rni::DarwinOsScheme'; do
    grep -qF "$sym" "$IOS_WORK/nm.txt" || MISSING+=("$sym")
  done
  [ "${#MISSING[@]}" = 0 ] || bad B "symbols missing from the library: ${MISSING[*]}"
  PLAT=$(otool -l "$LIB" 2> /dev/null | grep -m1 -A3 LC_BUILD_VERSION | sed -nE 's/.*platform ([0-9]+).*/\1/p')
  echo "lib: ${LIB#"$IOS_WORK"/} $(du -h "$LIB" | cut -f1) archs=$(lipo -archs "$LIB") platform=${PLAT:-?} (7 = iOS Simulator)"
  [ "$(lipo -archs "$LIB")" = arm64 ] && [ "$PLAT" = 7 ] || bad B "not an arm64 iOS Simulator library"
else
  bad B "build failed: $(grep -m5 -E 'error:' "$IOS_WORK/build.log" | tr '\n' ' ')"
fi
ios_keep "$IOS_WORK/build.log"
[ "${#FAILS[@]}" = 0 ] || { echo "IOS_CMAKE_CONFIGURE_FAIL (${FAILS[*]})"; exit 1; }
echo "IOS_CMAKE_CONFIGURE_PASS (lib=$(du -h "$LIB" | cut -f1))"
