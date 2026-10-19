#!/usr/bin/env bash
# iOS Phase 1 / Task 1.4 gate: the OS light/dark setting reaches the engine on
# iOS (OsAppearanceIOS.mm behind the unchanged OsAppearance.cpp watcher). The
# test host (--test=settings) logs the production OsAppearanceWatcher's
# initial value and every change it reports.
# Arms (each failure prints `IOS_OS_APPEARANCE_GATE FAIL <arm>: ...`):
#   I  with the simulator set to light before launch, the initial value is light
#   D  `simctl ui appearance dark` -> appearance_changed scheme=dark within 8 s
#   L  `simctl ui appearance light` -> appearance_changed scheme=light within 8 s
# A UIKit trait_change line is logged beside each flip, so a failure says
# whether the setting reached the app at all.
# Pass line: IOS_OS_APPEARANCE_PASS (light->dark->light). Mutants:
# tools/mutation-verify-os-appearance-ios.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
ios_begin appearance
FAILS=()
bad() { echo "IOS_OS_APPEARANCE_GATE FAIL $1: $2"; FAILS+=("$1"); }

ios_build_testhost || { echo "IOS_OS_APPEARANCE_FAIL (build)"; exit 1; }
ios_sim_up || { echo "IOS_OS_APPEARANCE_FAIL (simulator)"; exit 1; }
xcrun simctl ui "$IOS_UDID" appearance light
LOG="$IOS_WORK/app.log"
ios_launch "$LOG" settings || { echo "IOS_OS_APPEARANCE_FAIL (launch)"; exit 1; }
ios_wait_log "$LOG" 'testhost: settings_ready' 30 || { cat "$LOG"; echo "IOS_OS_APPEARANCE_FAIL (host not ready)"; exit 1; }
grep -q 'appearance_initial scheme=light' "$LOG" || bad I "initial: $(grep -m1 appearance_initial "$LOG")"
xcrun simctl ui "$IOS_UDID" appearance dark
ios_wait_log "$LOG" 'appearance_changed scheme=dark' 8 || bad D "no dark change in 8 s (simctl ui says $(xcrun simctl ui "$IOS_UDID" appearance))"
xcrun simctl ui "$IOS_UDID" appearance light
ios_wait_log "$LOG" 'appearance_changed scheme=light' 8 || bad L "no light change in 8 s"
sleep 1
cat "$LOG"
ios_keep "$LOG"
[ "${#FAILS[@]}" = 0 ] || { echo "IOS_OS_APPEARANCE_FAIL (${FAILS[*]})"; exit 1; }
echo "IOS_OS_APPEARANCE_PASS (light->dark->light)"
