#!/usr/bin/env bash
# iOS Phase 1 / Task 1.4 gate: iOS accessibility settings reach
# ReadAccessibilitySettings() (AccessibilitySettingsIOS.mm). The test host
# (--test=settings) polls the production function from a background thread
# every 200 ms and logs every change.
# How the switches are flipped in the simulator, from outside the app:
#   Reduce Motion: no `simctl ui` option exists, so the preference behind
#     Settings > Accessibility > Motion is written (com.apple.Accessibility
#     ReduceMotionEnabled) and its change notification posted. Measured: a
#     fresh process then reads UIAccessibilityIsReduceMotionEnabled()=1.
#   Increase Contrast: `simctl ui increase_contrast`, the supported toggle.
# Arms (each failure prints `IOS_REDUCE_MOTION_GATE FAIL <arm>: ...`):
#   I  initial: reduce_motion=0 increase_contrast=0 (both forced off first)
#   M  reduce motion on -> reduce_motion=1 within 5 s; off -> reduce_motion=0
#   C  increase contrast on -> increase_contrast=1 within 5 s
# Pass line: IOS_REDUCE_MOTION_PASS (reduce_motion 0->1->0, increase_contrast 0->1).
# Mutants: tools/mutation-verify-reduce-motion-ios.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
ios_begin reduce-motion
FAILS=()
bad() { echo "IOS_REDUCE_MOTION_GATE FAIL $1: $2"; FAILS+=("$1"); }
reduce_motion() {  # on|off
  local v=false
  [ "$1" = on ] && v=true
  xcrun simctl spawn "$IOS_UDID" defaults write com.apple.Accessibility ReduceMotionEnabled -bool "$v"
  xcrun simctl spawn "$IOS_UDID" notifyutil -p com.apple.accessibility.reduce.motion.status > /dev/null 2>&1
}

ios_build_testhost || { echo "IOS_REDUCE_MOTION_FAIL (build)"; exit 1; }
ios_sim_up || { echo "IOS_REDUCE_MOTION_FAIL (simulator)"; exit 1; }
reduce_motion off
xcrun simctl ui "$IOS_UDID" increase_contrast disabled
LOG="$IOS_WORK/app.log"
ios_launch "$LOG" settings || { echo "IOS_REDUCE_MOTION_FAIL (launch)"; exit 1; }
ios_wait_log "$LOG" 'testhost: settings initial ' 30 || { cat "$LOG"; echo "IOS_REDUCE_MOTION_FAIL (host not ready)"; exit 1; }
grep -q 'settings initial reduce_motion=0 .* increase_contrast=0 ' "$LOG" \
  || bad I "$(grep -m1 'settings initial' "$LOG")"
reduce_motion on
ios_wait_log "$LOG" 'testhost: settings reduce_motion=1 ' 5 || bad M "reduce motion on never read back as 1"
reduce_motion off
ios_wait_log "$LOG" 'testhost: settings reduce_motion=0 ' 5 || bad M "reduce motion off never read back as 0"
xcrun simctl ui "$IOS_UDID" increase_contrast enabled
ios_wait_log "$LOG" 'testhost: settings .*increase_contrast=1 ' 5 || bad C "increase contrast never read back as 1"
sleep 1
cat "$LOG"
ios_keep "$LOG"
[ "${#FAILS[@]}" = 0 ] || { echo "IOS_REDUCE_MOTION_FAIL (${FAILS[*]})"; exit 1; }
echo "IOS_REDUCE_MOTION_PASS (reduce_motion 0->1->0, increase_contrast 0->1)"
