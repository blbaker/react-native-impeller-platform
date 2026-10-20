#!/usr/bin/env bash
# iOS gate: the engine builds, links and signs for a real iPhone/iPad
# (iphoneos arm64, not the Simulator). Nothing runs: running needs an iPhone,
# or a Mac that can run iOS apps, either way with an iOS development
# provisioning profile (docs/eng/ios-platform.md, "Device builds").
#   bash tools/ci-ios-device-build.sh   (on linux: RNI_MAC_HOST=<ssh host> runs it on a Mac)
# Needs tools/sdk-fetch-ios.sh device (engine/third_party/impeller-sdk-ios-arm64)
# and the hermesvm.xcframework device slice (tools/hermes-build-ios.sh).
# Arms (each failure prints `IOS_DEVICE_BUILD_GATE FAIL <arm>: ...`):
#   B  the engine builds for iphoneos and the test host links against it
#   P  the app is an iPhone app: executable and hermesvm.framework are Mach-O
#      platform IOS (not IOSSIMULATOR), arm64, minos 15.1; Info.plist says iPhoneOS
#   R  one C++ exception runtime and one jsi: the executable carries no private
#      copy of __cxa_*/__gxx_personality_v0/std::terminate/rethrow_exception,
#      defines no jsi::JSError type info, and links libc++abi
#   S  the bundle's signature verifies (ad-hoc; a device install re-signs it)
# Pass line: IOS_DEVICE_BUILD_PASS (platform=IOS arch=arm64 app=<size>).
# Mutants: tools/mutation-verify-ios-device-build.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
IOS_PLATFORM=device
ios_begin ios-device-build
FAILS=()
bad() { echo "IOS_DEVICE_BUILD_GATE FAIL $1: $2"; FAILS+=("$1"); }

echo "== B: build =="
if ! bash tools/engine-build-ios.sh device > "$IOS_WORK/engine-build.log" 2>&1; then
  tail -25 "$IOS_WORK/engine-build.log"; echo "IOS_DEVICE_BUILD_FAIL (B: engine build)"; exit 1
fi
grep -E '^engine-build-ios: device' "$IOS_WORK/engine-build.log" | tail -1
if ! ios_build_testhost engine; then
  echo "IOS_DEVICE_BUILD_FAIL (B: test host link)"; exit 1
fi
EXE="$IOS_APP/RniTestHost"
HFW="$IOS_APP/Frameworks/hermesvm.framework/hermesvm"

echo "== P: an iPhone app =="
plat() { vtool -show-build "$1" 2> /dev/null | awk '/platform/{print $2; exit}'; }
minos() { vtool -show-build "$1" 2> /dev/null | awk '/minos/{print $2; exit}'; }
echo "executable: platform $(plat "$EXE") minos $(minos "$EXE") archs $(lipo -archs "$EXE")"
echo "hermesvm:   platform $(plat "$HFW") archs $(lipo -archs "$HFW" 2> /dev/null)"
[ "$(plat "$EXE")" = IOS ] || bad P "the executable is platform $(plat "$EXE"), not IOS"
[ "$(lipo -archs "$EXE")" = arm64 ] || bad P "the executable is $(lipo -archs "$EXE"), not arm64"
[ "$(minos "$EXE")" = 15.1 ] || bad P "minos is $(minos "$EXE"), not 15.1"
[ "$(plat "$HFW")" = IOS ] || bad P "hermesvm.framework is platform $(plat "$HFW"), not IOS"
SP=$(plutil -extract CFBundleSupportedPlatforms json -o - "$IOS_APP/Info.plist" 2> /dev/null)
[ "$SP" = '["iPhoneOS"]' ] || bad P "Info.plist CFBundleSupportedPlatforms is $SP, not [\"iPhoneOS\"]"

echo "== R: one C++ exception runtime, one jsi =="
PRIV=$(nm -m "$EXE" | grep -cE 'was a private external\) (___cxa_(throw|rethrow|begin_catch)|___gxx_personality_v0|__ZSt9terminatev|__ZSt17rethrow_exceptionSt13exception_ptr)$')
JSI=$(nm -gU "$EXE" | grep -c ' __ZTIN8facebook3jsi7JSErrorE$')
echo "private exception-runtime copies: $PRIV; jsi::JSError type info defined: $JSI"
[ "$PRIV" = 0 ] || bad R "$PRIV private C++ exception-runtime symbols linked in (from libimpeller.a?)"
[ "$JSI" = 0 ] || bad R "the executable defines jsi::JSError's type info (a second jsi beside Hermes's)"
otool -L "$EXE" | grep -q 'libc++abi' || bad R "the executable does not link libc++abi"

echo "== S: signature =="
if codesign --verify --deep --strict "$IOS_APP" > "$IOS_WORK/verify.log" 2>&1; then
  echo "codesign --verify --deep --strict: ok"
else
  bad S "codesign --verify: $(head -c 200 "$IOS_WORK/verify.log")"
fi

SIZE=$(du -sh "$IOS_APP" | awk '{print $1}')
(cd "$IOS_WORK" && ditto -c -k --keepParent RniTestHost.app "$IOS_ART/RniTestHost-iphoneos.zip")
echo "kept: $IOS_ART/RniTestHost-iphoneos.zip"
[ "${#FAILS[@]}" = 0 ] || { echo "IOS_DEVICE_BUILD_FAIL (${FAILS[*]})"; exit 1; }
echo "IOS_DEVICE_BUILD_PASS (platform=IOS arch=arm64 app=$SIZE)"
