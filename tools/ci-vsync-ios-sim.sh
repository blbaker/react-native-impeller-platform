#!/usr/bin/env bash
# iOS Phase 1 / Task 1.2 gate: DisplayLinkIOS paces presents on the iOS
# Simulator (the iOS counterpart of tools/ci-vsync.sh's pacing arm A). The test
# host (--test=vsync) draws a moving bar through MetalSurfaceIOS once per
# DisplayLinkIOS callback, on a serial raster queue, and presents it. After 30
# warm-up frames it reports 120 intervals of three clocks: displayed times, the
# return of each Present() call, and the link's own timestamps.
# Arms (each failure prints `IOS_VSYNC_GATE FAIL <arm>: ...`):
#   T  the result line arrives within 30 s. A link that never fires (never
#      added to a run loop) is a timeout here, never "0 frames, 0 jitter"
#   N  120 intervals were measured, and nominalPeriodUs() was known up front
#   M  one present per vsync: mean present interval within 5% of the period
#      the link reports (a dropped or doubled frame moves the mean)
#   J  steady pacing: interval stddev under 10% of the period
# Which clock: on a device, MTLDrawable presentedTime for both M and J. The iOS
# Simulator SDK's MTLDrawable has no addPresentedHandler/presentedTime
# (MetalSurfaceIOS reports 0), so there M uses the Present() call times and J
# the timestamps DisplayLinkIOS hands its sink (one per callback: a dropped or
# late callback is a 2x interval). The Present() call stddev is printed too; on
# the simulator it carries the host's GPU scheduling (measured 13% on a loaded
# Mac with the link itself at 0.01%), so it is reported, not gated.
# Pass line: IOS_VSYNC_PASS (mean=<us> stddev_pct=<pct>). Mutants:
# tools/mutation-verify-vsync-ios-sim.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
ios_begin vsync
FAILS=()
bad() { echo "IOS_VSYNC_GATE FAIL $1: $2"; FAILS+=("$1"); }

ios_build_testhost || { echo "IOS_VSYNC_FAIL (build)"; exit 1; }
ios_sim_up || { echo "IOS_VSYNC_FAIL (simulator)"; exit 1; }
LOG="$IOS_WORK/app.log"
ios_launch "$LOG" vsync || { echo "IOS_VSYNC_FAIL (launch)"; exit 1; }
if ! ios_wait_log "$LOG" 'testhost: vsync n=' 30; then
  bad T "no vsync result in 30 s (last progress: $(grep 'vsync_progress' "$LOG" | tail -1 || true))"
fi
cat "$LOG"
ios_keep "$LOG"
[ "${#FAILS[@]}" = 0 ] || { echo "IOS_VSYNC_FAIL (${FAILS[*]})"; exit 1; }

RES='testhost: vsync n='
NOMINAL=$(ios_kv "$LOG" 'testhost: vsync link_ok=' nominal_period_us)
PERIOD=$(ios_kv "$LOG" "$RES" period_us)
N=$(sed -nE 's/.*testhost: vsync n=([0-9]+) .*/\1/p' "$LOG" | head -1)
if [ "${N:-0}" -ge 120 ]; then
  SRC=presented MEAN=$(ios_kv "$LOG" "$RES" present_mean_us) SD=$(ios_kv "$LOG" "$RES" present_stddev_us)
else
  SRC="present_call+link" MEAN=$(ios_kv "$LOG" "$RES" call_mean_us) SD=$(ios_kv "$LOG" "$RES" link_stddev_us)
  N=$(ios_kv "$LOG" "$RES" call_n)
fi
echo "present_call intervals: mean_us=$(ios_kv "$LOG" "$RES" call_mean_us) stddev_us=$(ios_kv "$LOG" "$RES" call_stddev_us) (reported)"
echo "link timestamps: mean_us=$(ios_kv "$LOG" "$RES" link_mean_us) stddev_us=$(ios_kv "$LOG" "$RES" link_stddev_us)"
[ "${NOMINAL:-0}" -gt 0 ] || bad N "nominalPeriodUs() was ${NOMINAL:-unset} before the first callback"
[ "${N:-0}" -ge 120 ] || bad N "only ${N:-0} intervals"
[ "${PERIOD:-0}" -gt 0 ] && [ -n "$MEAN" ] && [ -n "$SD" ] || bad N "missing numbers: period=$PERIOD mean=$MEAN sd=$SD"
if [ "${#FAILS[@]}" = 0 ]; then
  read -r MPCT SPCT < <(python3 -c "p=$PERIOD; print('%.2f %.2f' % (abs($MEAN-p)/p*100, $SD/p*100))")
  echo "source=$SRC n=${N} period_us=$PERIOD nominal_us=$NOMINAL mean_us=$MEAN (off ${MPCT}%) gated_stddev_us=$SD (${SPCT}%)"
  python3 -c "import sys; sys.exit(0 if $MPCT <= 5 else 1)" || bad M "mean $MEAN us is ${MPCT}% off the ${PERIOD} us period"
  python3 -c "import sys; sys.exit(0 if $SPCT < 10 else 1)" || bad J "stddev $SD us is ${SPCT}% of the period"
fi
[ "${#FAILS[@]}" = 0 ] || { echo "IOS_VSYNC_FAIL (${FAILS[*]})"; exit 1; }
echo "IOS_VSYNC_PASS (mean=$MEAN stddev_pct=$SPCT source=$SRC)"
