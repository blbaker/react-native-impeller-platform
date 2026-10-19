#!/usr/bin/env bash
# iOS gate: the system keyboard's RANGE edits reach the engine and JS. An
# XCUITest (engine/ios/testhost/uitests/RniTextInputUITests.m, run like
# tools/ci-ios-input.sh's, no Xcode project) drives fixtures/ios-text-input:
# it types "teh " on the English keyboard into a field with RN's default
# autocorrect, then switches to the Japanese romaji keyboard, types "nihonn" in
# a second field and confirms the composition. Edits go through RNIEngine's
# UITextInput view (engine/ios/RNITextInputView.mm) to
# FabricHost::replaceTextInputRange.
#   bash tools/ci-ios-text-input.sh   (on linux: RNI_MAC_HOST=<ssh host> runs it on a Mac)
# Arms (each failure prints `IOS_TEXT_INPUT_GATE FAIL <arm>: ...`):
#   X  the XCUITest passed (both keyboards present, every key found)
#   A  autocorrect: the keyboard replaced a range (rni-ios: text replace, or a
#      delete + insert) and JS's last value for the field is exactly "the "
#   C  the same keys in an autoCorrect={false} field stay "teh " (the field's
#      props reach the keyboard)
#   M  marked text: the composition reached the engine while still marked
#      (rni-ios: text marked) and JS saw kana before the commit
#   J  commit: the composition was unmarked and JS's last value is "にほん"
# Pass line: IOS_TEXT_INPUT_PASS (auto="the " off="teh " ja="にほん").
# Mutants: tools/mutation-verify-ios-text-input.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-uitest.sh"
ios_begin ios-text-input
FAILS=()
bad() { echo "IOS_TEXT_INPUT_GATE FAIL $1: $2"; FAILS+=("$1"); }
GEOM=fixtures/ios-text-input/geometry.js
geo() { python3 -c "import sys; sys.path.insert(0, 'tools'); import ios_image_check as c; g = c.load_geometry('$GEOM'); print($1)"; }
AX=$(geo "g['auto']['x'] + g['auto']['width'] / 2"); AY=$(geo "g['auto']['y'] + g['auto']['height'] / 2")
JX=$(geo "g['ja']['x'] + g['ja']['width'] / 2"); JY=$(geo "g['ja']['y'] + g['ja']['height'] / 2")
OX=$(geo "g['off']['x'] + g['off']['width'] / 2"); OY=$(geo "g['off']['y'] + g['off']['height'] / 2")
O_TYPED=$(geo "g['off']['typed']"); O_WANT=$(geo "g['off']['want']")
A_TYPED=$(geo "g['auto']['typed']"); A_WANT=$(geo "g['auto']['want']")
J_TYPED=$(geo "g['ja']['typed']"); J_WANT=$(geo "g['ja']['want']")

bash tools/engine-build-ios.sh simulator > "$IOS_WORK/engine-build.log" 2>&1 \
  || { tail -25 "$IOS_WORK/engine-build.log"; echo "IOS_TEXT_INPUT_FAIL (engine build)"; exit 1; }
ios_build_testhost engine || { echo "IOS_TEXT_INPUT_FAIL (test host build)"; exit 1; }
ios_build_uitest engine/ios/testhost/uitests/RniTextInputUITests.m RniTextInputUITests \
  || { echo "IOS_TEXT_INPUT_FAIL (uitest build)"; exit 1; }
ios_sim_up || { echo "IOS_TEXT_INPUT_FAIL (simulator)"; exit 1; }
# English + Japanese romaji software keyboards (Settings > Keyboards). ⛔ Set
# on a running simulator they never reach the keyboard (measured: no globe
# key), so write them, then reboot the simulator once.
xcrun simctl spawn "$IOS_UDID" defaults write -g AppleKeyboards -array \
  "en_US@sw=QWERTY;hw=Automatic" "ja_JP-Romaji@sw=QWERTY-Japanese;hw=Automatic"
xcrun simctl spawn "$IOS_UDID" defaults write -g AppleKeyboardsExpanded -bool true
{ xcrun simctl shutdown "$IOS_UDID" && xcrun simctl boot "$IOS_UDID" \
    && xcrun simctl bootstatus "$IOS_UDID" -b; } >> "$IOS_WORK/sim.log" 2>&1 \
  || { echo "IOS_TEXT_INPUT_FAIL (simulator reboot: $(tail -2 "$IOS_WORK/sim.log"))"; exit 1; }
echo "keyboards: $(xcrun simctl spawn "$IOS_UDID" defaults read -g AppleKeyboards | tr -d ' \n')"
sleep 5

XLOG="$IOS_WORK/xcodebuild.log"
ios_run_uitest RniTextInputUITests "$XLOG" RNI_UITEST_APP="$IOS_BID" \
  RNI_UITEST_ARGS="--test=engine --bundle=ios-text-input.jsbundle --app=IosTextInput --log-file=1" \
  RNI_TAP_AUTO_X="$AX" RNI_TAP_AUTO_Y="$AY" RNI_TAP_OFF_X="$OX" RNI_TAP_OFF_Y="$OY" \
  RNI_TAP_JA_X="$JX" RNI_TAP_JA_Y="$JY" RNI_TYPE_AUTO="$A_TYPED" RNI_TYPE_OFF="$O_TYPED" \
  RNI_TYPE_JA="$J_TYPED" RNI_UITEST_SHOT="$IOS_WORK/screen.png"
XRC=$?
grep -E 'rni-uitest|error:|Test Case .* (passed|failed)|TEST (SUCCEEDED|FAILED|EXECUTE)' "$XLOG" \
  | cut -c1-400 | head -24
[ "$XRC" = 0 ] || bad X "xcodebuild rc=$XRC: $(grep -m1 -E 'error:|failed' "$XLOG" | cut -c1-300)"

LOG="$IOS_WORK/app.log"
cp "$(ios_container)/Documents/testhost.log" "$LOG" 2> /dev/null || : > "$LOG"
grep -E 'rni-ios: (keyboard (traits|first)|text )|\[js\] ios-text' "$LOG" | head -60
ios_keep "$LOG" "$XLOG" "$IOS_WORK/screen.png"
last() { grep -F "[js] ios-text $1=" "$LOG" | tail -1 | sed -E "s/.*ios-text $1=//"; }

echo "== A: autocorrect =="
A_LAST=$(last auto)
echo "last auto: ${A_LAST:-none} (typed \"$A_TYPED\", want \"$A_WANT\")"
grep -qE 'rni-ios: text (replace|delete)' "$LOG" || bad A "the keyboard never replaced or deleted a range"
[ "$A_LAST" = "\"$A_WANT\"" ] || bad A "JS value is ${A_LAST:-none}, not \"$A_WANT\""

echo "== C: autoCorrect={false} =="
O_LAST=$(last off)
echo "last off: ${O_LAST:-none} (typed \"$O_TYPED\", want \"$O_WANT\")"
[ "$O_LAST" = "\"$O_WANT\"" ] || bad C "JS value is ${O_LAST:-none}, not \"$O_WANT\""

echo "== M: marked text =="
grep -q 'rni-ios: text marked len=[1-9]' "$LOG" || bad M "no marked text reached the engine"
grep -F '[js] ios-text ja=' "$LOG" | grep -q '[ぁ-ん]' || bad M "JS never saw kana while composing"

echo "== J: commit =="
J_LAST=$(last ja)
echo "last ja: ${J_LAST:-none} (typed \"$J_TYPED\", want \"$J_WANT\")"
grep -q 'rni-ios: text unmark' "$LOG" || bad J "the composition was never unmarked"
[ "$J_LAST" = "\"$J_WANT\"" ] || bad J "JS value is ${J_LAST:-none}, not \"$J_WANT\""

[ "${#FAILS[@]}" = 0 ] || { echo "IOS_TEXT_INPUT_FAIL (${FAILS[*]})"; exit 1; }
echo "IOS_TEXT_INPUT_PASS (auto=\"$A_WANT\" off=\"$O_WANT\" ja=\"$J_WANT\")"
