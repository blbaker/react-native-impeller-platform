#!/usr/bin/env bash
# iOS Phase 1 / Task 1.4 gate: the OS light/dark setting reaches the engine on
# iOS (OsAppearanceIOS.mm behind the unchanged OsAppearance.cpp watcher). The
# test host (--test=settings) logs the production OsAppearanceWatcher's
# initial value and every change it reports, plus UIKit's own trait changes.
# Arms (each failure prints `IOS_OS_APPEARANCE_GATE FAIL <arm>: ...`):
#   I  with the simulator light at launch, the initial value is light
#   D  after UIKit reports dark (trait_change style=2), the engine reports
#      appearance_changed scheme=dark within 8 s
#   L  same back to light (style=1 -> scheme=light)
# Delivery vs. reporting: `simctl ui appearance` does not always reach the app
# (measured once in ~20 runs: the app's UIKit saw no dark trait at all). So a
# flip is re-issued (away and back) until UIKit in the app reports it, at most
# 3 tries, and only then is the engine's own report gated. A flip UIKit never
# delivers is a FAIL that names the simulator, not the engine. The mutants keep
# UIKit delivery intact and break only the engine's reporting.
# Pass line: IOS_OS_APPEARANCE_PASS (light->dark->light). Mutants:
# tools/mutation-verify-os-appearance-ios.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
ios_begin appearance
FAILS=()
bad() { echo "IOS_OS_APPEARANCE_GATE FAIL $1: $2"; FAILS+=("$1"); }
count() { grep -c "$1" "$LOG" 2> /dev/null || true; }
wait_more() {  # pattern n_before seconds -> 0 once the pattern occurs more than n_before times
  local i=0
  while [ $i -lt $(($3 * 4)) ]; do
    [ "$(count "$1")" -gt "$2" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}
flip() {  # scheme style -> 0 once UIKit in the app reported the new style
  local other=light try n
  [ "$1" = light ] && other=dark
  for try in 1 2 3; do
    n=$(count "trait_change style=$2")
    xcrun simctl ui "$IOS_UDID" appearance "$1"
    wait_more "trait_change style=$2" "$n" 6 && return 0
    echo "appearance: '$1' not delivered to the app (try $try, simctl ui says $(xcrun simctl ui "$IOS_UDID" appearance))"
    xcrun simctl ui "$IOS_UDID" appearance "$other"
    sleep 2
  done
  return 1
}

ios_build_testhost || { echo "IOS_OS_APPEARANCE_FAIL (build)"; exit 1; }
ios_sim_up || { echo "IOS_OS_APPEARANCE_FAIL (simulator)"; exit 1; }
[ "$(xcrun simctl ui "$IOS_UDID" appearance)" = light ] || xcrun simctl ui "$IOS_UDID" appearance light
LOG="$IOS_WORK/app.log"
ios_launch "$LOG" settings || { echo "IOS_OS_APPEARANCE_FAIL (launch)"; exit 1; }
ios_wait_log "$LOG" 'testhost: settings_ready' 30 || { cat "$LOG"; echo "IOS_OS_APPEARANCE_FAIL (host not ready)"; exit 1; }
grep -q 'appearance_initial scheme=light' "$LOG" || bad I "initial: $(grep -m1 appearance_initial "$LOG")"
if flip dark 2; then
  ios_wait_log "$LOG" 'appearance_changed scheme=dark' 8 || bad D "UIKit reported dark, the engine did not within 8 s"
else
  bad D "the simulator never delivered dark to the app (3 tries)"
fi
N_LIGHT=$(count 'appearance_changed scheme=light')
if flip light 1; then
  wait_more 'appearance_changed scheme=light' "$N_LIGHT" 8 || bad L "UIKit reported light, the engine did not within 8 s"
else
  bad L "the simulator never delivered light to the app (3 tries)"
fi
sleep 1
cat "$LOG"
ios_keep "$LOG"
[ "${#FAILS[@]}" = 0 ] || { echo "IOS_OS_APPEARANCE_FAIL (${FAILS[*]})"; exit 1; }
echo "IOS_OS_APPEARANCE_PASS (light->dark->light)"
