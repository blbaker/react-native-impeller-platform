#!/usr/bin/env bash
# iOS Phase 1 / Task 1.3 gate: no GPU work while backgrounded (the iOS
# counterpart of tools/ci-gpu-availability.sh, FP-31). The test host
# (--test=gpu) calls the production InstallGpuAvailabilityObservers() and runs
# a raster thread that, inside a rni::gpu::Section, draws + presents onscreen
# and draws offscreen every 16 ms. The gate backgrounds it for real (simctl
# launches Settings over it; the host holds a background task so the process
# keeps running), then brings it back.
# Arms (each failure prints `IOS_GPU_AVAILABILITY_GATE FAIL <arm>: ...`):
#   F  the switch flipped through the production observers:
#      gpu_availability state=unavailable reason=ios_background, then
#      state=available reason=ios_foreground
#   Z  between background+0.1 s and +1.1 s: presents, onscreen draws and
#      offscreen draws all advance by 0, while >= 5 skipped frames are counted
#      (the raster thread kept asking, so the zeros are not an idle app).
#      Measured in that window: 13-25 skips with the switch, 8-11 presents per
#      second without it (iOS throttles a backgrounded app's 16 ms loop).
#   R  1 s after the (last) foreground, presents advance again
# Pass line: IOS_GPU_AVAILABILITY_PASS (presents_during_bg=0). Mutants:
# tools/mutation-verify-gpu-availability-ios.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
ios_begin gpu
FAILS=()
bad() { echo "IOS_GPU_AVAILABILITY_GATE FAIL $1: $2"; FAILS+=("$1"); }
sample() { ios_kv "$LOG" "gpu_sample tag=$1 " "$2"; }
# The LAST sample of a tag: launch itself posts a foreground notification.
sample_last() { grep -E "gpu_sample tag=$1 " "$LOG" | tail -1 | sed -nE "s/.*[ ]$2=([^ ]+).*/\1/p"; }

ios_build_testhost || { echo "IOS_GPU_AVAILABILITY_FAIL (build)"; exit 1; }
ios_sim_up || { echo "IOS_GPU_AVAILABILITY_FAIL (simulator)"; exit 1; }
LOG="$IOS_WORK/app.log"
ios_launch "$LOG" gpu || { echo "IOS_GPU_AVAILABILITY_FAIL (launch)"; exit 1; }
ios_wait_log "$LOG" 'gpu_sample tag=ready ' 30 || { cat "$LOG"; echo "IOS_GPU_AVAILABILITY_FAIL (never rendered)"; exit 1; }
xcrun simctl launch "$IOS_UDID" com.apple.Preferences > /dev/null || bad Z "could not launch Settings over the host"
ios_wait_log "$LOG" 'gpu_sample tag=bg_end ' 20 || bad Z "no bg_end sample (did the host reach the background?)"
FG0=$(grep -c 'gpu_sample tag=fg_after ' "$LOG")   # launch itself already logged one
xcrun simctl launch "$IOS_UDID" "$IOS_BID" > /dev/null || bad R "could not bring the host back"
for _ in $(seq 80); do
  [ "$(grep -c 'gpu_sample tag=fg_after ' "$LOG")" -gt "$FG0" ] && break
  sleep 0.25
done
[ "$(grep -c 'gpu_sample tag=fg_after ' "$LOG")" -gt "$FG0" ] || bad R "no fg_after sample after the return (did the host come back?)"
cat "$LOG"
ios_keep "$LOG"

echo "== F: the switch =="
grep -q 'gpu_availability state=unavailable reason=ios_background ' "$LOG" \
  || bad F "no unavailable flip from the background notification"
grep -q 'gpu_availability state=available reason=ios_foreground ' "$LOG" \
  || bad F "no available flip from the foreground notification"

echo "== Z: background window =="
DUR=() ; for k in presents draws offscreen skipped; do
  a=$(sample bg_start "$k"); b=$(sample bg_end "$k")
  DUR+=("$k=$(( ${b:-0} - ${a:-0} ))")
  eval "D_$k=$(( ${b:-0} - ${a:-0} ))"
done
echo "during background (bg_start -> bg_end, 1 s): ${DUR[*]}"
# shellcheck disable=SC2154
{ [ "$D_presents" = 0 ] && [ "$D_draws" = 0 ] && [ "$D_offscreen" = 0 ]; } \
  || bad Z "GPU work in the background: ${DUR[*]}"
# shellcheck disable=SC2154
[ "$D_skipped" -ge 5 ] || bad Z "only $D_skipped skipped frames (${DUR[*]}): the raster thread was not really running"

echo "== R: restore =="
P_FG=$(sample_last foreground presents); P_AFTER=$(sample_last fg_after presents)
echo "presents at foreground=${P_FG:-?} 1 s later=${P_AFTER:-?}"
[ "$(( ${P_AFTER:-0} - ${P_FG:-0} ))" -gt 0 ] || bad R "presents did not resume after the foreground"

[ "${#FAILS[@]}" = 0 ] || { echo "IOS_GPU_AVAILABILITY_FAIL (${FAILS[*]})"; exit 1; }
# shellcheck disable=SC2154
echo "IOS_GPU_AVAILABILITY_PASS (presents_during_bg=$D_presents skipped_during_bg=$D_skipped)"
