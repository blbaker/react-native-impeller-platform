#!/usr/bin/env bash
# iOS Phase 4 spike gate: REAL UIKit input reaches the engine. An XCUITest
# (engine/ios/testhost/uitests/RniInputUITests.m, run by xcodebuild from a
# hand-written .xctestrun; tools/lib/ios-uitest.sh) launches the engine test
# host on fixtures/ios-input, taps the Pressable, taps the TextInput, and types
# on the software keyboard, key by key. Touches go through RNIEngine's gesture
# recognizer (engine/ios/RNIInputIOS.mm); keys through its UIKeyInput proxy.
#   bash tools/ci-ios-input.sh   (on linux: RNI_MAC_HOST=<ssh host> runs it on a Mac)
# Arms (each failure prints `IOS_INPUT_GATE FAIL <arm>: ...`):
#   X  the XCUITest passed (the software keyboard appeared and had every key)
#   T  touch: the tap on the button hit a tag and JS saw onPress (pressed=1);
#      the screenshot shows the button in its pressed color
#   K  keyboard: the tap on the field focused it (textinput_focus != 0, JS
#      onFocus) and UIKit reported the keyboard shown
#   I  input: JS's last onChangeText value is exactly the typed text
# Pass line: IOS_INPUT_PASS (typed="<text>"). Mutants: tools/mutation-verify-ios-input.sh.
# Diagnosis: IOS_INPUT_TEST=textfield runs the same UI test against a plain
# UIKit UITextField (engine/ios/testhost/TestHostTextFieldControl.mm) instead of
# the engine. Arms T and K then fail by design (no engine lines), but arm I
# passing proves the simulator and XCUITest deliver key text at all.
# ⛔ A fresh simulator covers the keys with a "Slide to Type" tutorial on the
# first keyboard. Taps on the keys then land on the card, nothing is typed, and
# XCUITest logs "Computed hit point {-1, -1}". The UI test dismisses the card
# ("Continue"). The DidShowContinuousPathIntroduction default does not
# suppress it on iOS 26.3 (measured).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-uitest.sh"
ios_begin ios-input
FAILS=()
bad() { echo "IOS_INPUT_GATE FAIL $1: $2"; FAILS+=("$1"); }
GEOM=fixtures/ios-input/geometry.js
geo() { python3 -c "import sys; sys.path.insert(0, 'tools'); import ios_image_check as c; g = c.load_geometry('$GEOM'); print($1)"; }
BX=$(geo "g['button']['x'] + g['button']['width'] / 2"); BY=$(geo "g['button']['y'] + g['button']['height'] / 2")
IX=$(geo "g['input']['x'] + g['input']['width'] / 2"); IY=$(geo "g['input']['y'] + g['input']['height'] / 2")
TYPED=$(geo "g['typed']"); PRESSED=$(geo "','.join(str(int(g['button']['pressedColor'][i:i+2], 16)) for i in (1, 3, 5))")

bash tools/engine-build-ios.sh simulator > "$IOS_WORK/engine-build.log" 2>&1 \
  || { tail -25 "$IOS_WORK/engine-build.log"; echo "IOS_INPUT_FAIL (engine build)"; exit 1; }
ios_build_testhost engine || { echo "IOS_INPUT_FAIL (test host build)"; exit 1; }
ios_build_uitest engine/ios/testhost/uitests/RniInputUITests.m RniInputUITests || { echo "IOS_INPUT_FAIL (uitest build)"; exit 1; }
ios_sim_up || { echo "IOS_INPUT_FAIL (simulator)"; exit 1; }

XLOG="$IOS_WORK/xcodebuild.log"
ios_run_uitest RniInputUITests "$XLOG" RNI_UITEST_APP="$IOS_BID" \
  RNI_UITEST_ARGS="--test=${IOS_INPUT_TEST:-engine} --bundle=ios-input.jsbundle --app=IosInput --log-file=1" \
  RNI_TAP_BUTTON_X="$BX" RNI_TAP_BUTTON_Y="$BY" RNI_TAP_INPUT_X="$IX" RNI_TAP_INPUT_Y="$IY" \
  RNI_UITEST_TYPE="$TYPED" RNI_UITEST_SHOT="$IOS_WORK/screen.png"
XRC=$?
grep -E 'rni-uitest|error:|Test Case .* (passed|failed)|TEST (SUCCEEDED|FAILED|EXECUTE)' "$XLOG" | head -20
[ "$XRC" = 0 ] || bad X "xcodebuild rc=$XRC: $(grep -m1 -E 'error:|failed' "$XLOG")"

LOG="$IOS_WORK/app.log"
cp "$(ios_container)/Documents/testhost.log" "$LOG" 2> /dev/null || : > "$LOG"
grep -E 'rni-ios: (touch_down|keyboard|key )|\[js\] ios-input|engine first_frame' "$LOG" | head -30
ios_keep "$LOG" "$XLOG" "$IOS_WORK/screen.png"

echo "== T: touch =="
grep -qE "rni-ios: touch_down hit=[1-9][0-9]* textinput_focus=0 " "$LOG" || bad T "no touch_down with a hit on the button"
grep -qF '[js] ios-input pressed=1' "$LOG" || bad T "JS never saw onPress"
SCALE=$(sed -nE 's/.*testhost: engine uikit_points=[0-9]+x[0-9]+ uikit_scale=([0-9.]+).*/\1/p' "$LOG" | head -1)
if [ -s "$IOS_WORK/screen.png" ] && [ -n "$SCALE" ]; then
  P=$(python3 -c "
import sys; sys.path.insert(0, 'tools'); import ios_image_check as c
img = c.read_image('$IOS_WORK/screen.png'); s = $SCALE
print(','.join(map(str, c.px(img, int($BX * s), int($BY * s)))))")
  echo "button pixel after the tap: $P (pressed color $PRESSED)"
  [ "$P" = "$PRESSED" ] || bad T "button is $P on screen, not the pressed $PRESSED"
else
  bad T "no screenshot from the UI test, or no uikit_scale line"
fi

echo "== K: keyboard =="
grep -qE "rni-ios: touch_down hit=[0-9]+ textinput_focus=[1-9]" "$LOG" || bad K "the tap on the field focused nothing"
grep -qF '[js] ios-input focus=1' "$LOG" || bad K "JS never saw onFocus"
grep -q 'rni-ios: keyboard shown' "$LOG" || bad K "UIKit never reported the keyboard shown"

echo "== I: input =="
LAST=$(grep -F '[js] ios-input value=' "$LOG" | tail -1 | sed -E 's/.*value=//')
echo "last onChangeText: ${LAST:-none} (want \"$TYPED\")"
[ "$LAST" = "\"$TYPED\"" ] || bad I "JS value is ${LAST:-none}, not \"$TYPED\""

[ "${#FAILS[@]}" = 0 ] || { echo "IOS_INPUT_FAIL (${FAILS[*]})"; exit 1; }
echo "IOS_INPUT_PASS (typed=\"$TYPED\")"
