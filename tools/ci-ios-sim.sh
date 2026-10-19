#!/usr/bin/env bash
# iOS host phase / Task 3.3: the M1 gate. A React Native bundle renders through
# the engine on the iOS Simulator: RNIEngine (engine/ios/RNIEngine.mm) boots
# EngineSession on a CAMetalLayer and paints fixtures/ios-smoke.
#   bash tools/ci-ios-sim.sh   (on linux: RNI_MAC_HOST=<ssh host> runs it on a Mac)
# Builds the iOS engine (tools/engine-build-ios.sh, incremental), the test host
# against it (tools/lib/ios-sim.sh, `ios_build_testhost engine`), boots a fresh
# simulator, launches --test=engine, waits for the engine's own idle marker
# (`rni-ios: engine first_frame`: the first frame with content presented after
# the bundle evaluated and the surface started), then screenshots.
# Arms (each failure prints `IOS_SIM_GATE FAIL <arm>: ...`):
#   B  boot: the engine booted (JS idle after evaluate and after startSurface)
#      and reported its first frame within 60 s
#   P  pixels: every fixture box and the nested child are their exact colors at
#      the fixture's own coordinates (fixtures/ios-smoke/geometry.js, points x
#      UIKit's scale, not the engine's), the rounded box's corner is background, the
#      label band has ink (tools/ios_image_check.py smoke)
#   F  frames: presents keep coming (>= 120) after the first frame
#   L  lifecycle: a second launch with --detach-after=90 detaches and re-attaches
#      the engine (one EngineSession), and frames resume after it
# Pass line: IOS_SIM_PASS (box_rgb_match=1 colors=<n>). Mutants:
# tools/mutation-verify-ios-sim.sh. IOS_SIM_SHOT_EARLY=1 screenshots right after
# launch instead of after the idle marker (the plan's timing mutant).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
ios_begin ios-sim
FAILS=()
bad() { echo "IOS_SIM_GATE FAIL $1: $2"; FAILS+=("$1"); }
GEOM=fixtures/ios-smoke/geometry.js

bash tools/engine-build-ios.sh simulator > "$IOS_WORK/engine-build.log" 2>&1 \
  || { tail -25 "$IOS_WORK/engine-build.log"; echo "IOS_SIM_FAIL (engine build)"; exit 1; }
grep 'engine-build-ios:' "$IOS_WORK/engine-build.log" | tail -1
ios_build_testhost engine || { echo "IOS_SIM_FAIL (test host build)"; exit 1; }
ios_sim_up || { echo "IOS_SIM_FAIL (simulator)"; exit 1; }

LOG="$IOS_WORK/app.log"
ios_launch "$LOG" engine || { echo "IOS_SIM_FAIL (launch)"; exit 1; }
if [ "${IOS_SIM_SHOT_EARLY:-0}" = 1 ]; then
  :   # mutant: screenshot as soon as the app process is up, no idle marker
else
  ios_wait_log "$LOG" 'rni-ios: engine first_frame ' 60 || bad B "no first frame in 60 s: $(tail -3 "$LOG" | tr '\n' ' ')"
  ios_wait_log "$LOG" 'testhost: engine presented=(1[2-9][0-9]|[2-9][0-9][0-9])' 20 \
    || bad F "presents stopped: $(grep 'engine presented=' "$LOG" | tail -1)"
fi
ios_screenshot "$IOS_WORK/screen.png" || bad P "simctl screenshot failed"
cat "$LOG"
grep -q 'rni-ios: engine booted .* js_idle_after_eval=1 js_idle_after_start=1' "$LOG" \
  || bad B "boot: $(grep -m1 'engine booted\|boot_failed\|attach_failed\|init_failed' "$LOG" || echo 'no boot line')"

echo "== P: pixels =="
# UIKit's scale (the test host's own log line), NOT the engine's: an engine
# that lays out at the wrong scale must not also move the probes.
SCALE=$(sed -nE 's/.*testhost: engine uikit_points=[0-9]+x[0-9]+ uikit_scale=([0-9.]+).*/\1/p' "$LOG" | head -1)
if [ -n "$SCALE" ] && [ -s "$IOS_WORK/screen.png" ]; then
  P_OUT=$(python3 tools/ios_image_check.py smoke "$IOS_WORK/screen.png" "$GEOM" "$SCALE") || bad P "$P_OUT"
  echo "screen: $P_OUT"
else
  bad P "no uikit_scale line or no screenshot"
fi
ios_keep "$LOG" "$IOS_WORK/screen.png"

echo "== L: detach / re-attach =="
LOG2="$IOS_WORK/app-lifecycle.log"
if ios_launch "$LOG2" engine --detach-after=90 && ios_wait_log "$LOG2" 'engine_reattached=' 60; then
  N0=$(sed -nE 's/.*engine_reattached=1 presented_at_detach=([0-9]+).*/\1/p' "$LOG2" | head -1)
  ios_wait_log "$LOG2" 'testhost: engine presented=(2[4-9][0-9]|[3-9][0-9][0-9])' 20
  N1=$(grep 'testhost: engine presented=' "$LOG2" | tail -1 | sed -nE 's/.*presented=([0-9]+).*/\1/p')
  BOOTS=$(grep -c 'rni-ios: engine booted' "$LOG2")
  echo "lifecycle: presented_at_detach=${N0:-?} later=${N1:-?} boots=$BOOTS"
  [ -n "$N0" ] && [ "${N1:-0}" -gt "${N0:-0}" ] && [ "$BOOTS" = 1 ] \
    || bad L "re-attach: at_detach=${N0:-none} later=${N1:-none} boots=$BOOTS"
else
  bad L "no engine_reattached line: $(tail -2 "$LOG2" | tr '\n' ' ')"
fi
ios_keep "$LOG2"

[ "${#FAILS[@]}" = 0 ] || { echo "IOS_SIM_FAIL (${FAILS[*]})"; exit 1; }
COLORS=$(sed -nE 's/.* colors=([0-9]+) .*/\1/p' <<< "$P_OUT")
echo "IOS_SIM_PASS (box_rgb_match=1 colors=$COLORS)"
