#!/bin/bash
# iOS Phase 0 / Task 0.3: build the CAMetalLayer smoke app for the iOS
# Simulator, run it in a fresh simulator, screenshot, check the colors.
# Runs ON THE MAC (Xcode + Simulator). Two arms:
#   present   - must print IOS_METAL_SMOKE_PASS
#   nopresent - mutant (draws, skips ImpellerSurfacePresent): must FAIL the check
# Final line: IOS_METAL_SMOKE_GATE_PASS / IOS_METAL_SMOKE_GATE_FAIL.
#
# RNI_IOS_SDK: the staged iOS Simulator Impeller SDK (include/impeller.h +
# lib/libimpeller.a; tools/sdk-fetch-ios.sh builds it).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
SDK="${RNI_IOS_SDK:-$HERE/../../third_party/impeller-sdk-ios-simulator-arm64}"
LIB="$SDK/lib/libimpeller.a"
INC="$SDK/include"
W="${SMOKE_WORK:-$HERE/work}"
APP="$W/RniMetalSmoke.app"
BID=dev.rnimpeller.metalsmoke
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"   # system python3 for the checker
mkdir -p "$W"
[ -f "$LIB" ] || { echo "smoke: FAIL: no $LIB (run tools/sdk-fetch-ios.sh first)"; exit 2; }

echo "smoke: building $(xcodebuild -version | head -1), lib $(du -h "$LIB" | cut -f1)"
rm -rf "$APP" && mkdir -p "$APP"
xcrun --sdk iphonesimulator clang++ -std=c++20 -fobjc-arc -target arm64-apple-ios15.0-simulator \
  -I "$INC" "$HERE/main.mm" "$LIB" \
  -framework UIKit -framework Metal -framework MetalPerformanceShaders -framework QuartzCore \
  -framework CoreGraphics -framework CoreText -framework Foundation -lc++ \
  -o "$APP/RniMetalSmoke" > "$W/build.log" 2>&1 \
  || { echo "smoke: FAIL: build"; head -30 "$W/build.log"; exit 2; }
cp "$HERE/Info.plist" "$APP/Info.plist"
codesign --force --sign - --timestamp=none "$APP" > "$W/sign.log" 2>&1 \
  || { echo "smoke: FAIL: codesign"; cat "$W/sign.log"; exit 2; }
echo "smoke: app $(du -sh "$APP" | cut -f1), $(vtool -show-build "$APP/RniMetalSmoke" | grep -E 'platform|minos' | tr -s ' ' | tr '\n' ' ')"

RT=$(xcrun simctl list runtimes | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS-26-3' | head -1)
DT=com.apple.CoreSimulator.SimDeviceType.iPhone-16   # 3x scale, Dynamic Island
UDID=$(xcrun simctl create rni-metal-smoke "$DT" "$RT") || { echo "smoke: FAIL: simctl create"; exit 2; }
cleanup() { xcrun simctl shutdown "$UDID" >/dev/null 2>&1; xcrun simctl delete "$UDID" >/dev/null 2>&1; }
trap cleanup EXIT
xcrun simctl boot "$UDID" && xcrun simctl bootstatus "$UDID" -b > "$W/boot.log" 2>&1
xcrun simctl install "$UDID" "$APP" || { echo "smoke: FAIL: install"; exit 2; }
echo "smoke: simulator ${DT##*.} ${RT##*.} ($UDID)"

# A fresh simulator posts first-boot system banners ("Ready for Apple
# Intelligence") over whatever app is up. Let them arrive before the first arm,
# and give each arm up to 3 screenshots 4 s apart: an arm PASSES the color check
# if any shot passes. Same rule for both arms, so the mutant gets the same chances.
sleep 10
declare -i GATE=0
for MODE in present nopresent; do
  : > "$W/app-$MODE.log"; : > "$W/app-$MODE.err"   # simctl --stdout appends
  xcrun simctl launch --terminate-running-process --stdout="$W/app-$MODE.log" \
    --stderr="$W/app-$MODE.err" "$UDID" "$BID" "--mode=$MODE" > /dev/null \
    || { echo "smoke: FAIL: launch $MODE"; exit 2; }
  sleep 4   # launch animation done, 120+ frames drawn
  RC=1
  for TRY in 1 2 3; do
    xcrun simctl io "$UDID" screenshot --type=png "$W/shot-$MODE.png" > /dev/null 2>&1
    V=$(python3 "$HERE/check_png.py" "$W/shot-$MODE.png"); RC=$?
    echo "smoke[$MODE] shot $TRY: $V"
    [ $RC -eq 0 ] && break
    sleep 4
  done
  sed 's/^/  app: /' "$W/app-$MODE.log"
  if [ "$MODE" = present ]; then [ $RC -eq 0 ] || GATE=1
  else [ $RC -ne 0 ] && echo "smoke[$MODE]: mutant caught" || { echo "smoke[$MODE]: MUTANT SURVIVED"; GATE=1; }
  fi
done
xcrun simctl terminate "$UDID" "$BID" > /dev/null 2>&1
[ $GATE -eq 0 ] && echo "IOS_METAL_SMOKE_GATE_PASS" || echo "IOS_METAL_SMOKE_GATE_FAIL"
exit $GATE
