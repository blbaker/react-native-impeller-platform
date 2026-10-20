#!/usr/bin/env bash
# iOS gate: requestAnimationFrame is paced to RNIEngine's display link, not the
# 16 ms timer fallback. Runs the desktop rAF gate's own fixture
# (fixtures/native-anim-dots, app RafSemantics; tools/ci-raf-pacing.sh arm A) in
# the engine test host and reads the engine's rAF counters (--log-raf=1).
#   bash tools/ci-ios-raf.sh   (on linux: RNI_MAC_HOST=<ssh host> runs it on a Mac)
# Arms (each failure prints `IOS_RAF_GATE FAIL <arm>: ...`):
#   C  the rAF contract: same-batch cancel, cancel-before-flush, a throwing
#      callback neither stops the rest nor goes unreported, a rAF registered
#      inside a callback runs on a LATER frame
#      (rafsem a=1 b=0 c=1 d=0 nested_later=1, plus the [js-exception] line).
#      Until the C++ exception-runtime fix in tools/impeller-sdk-ios-build.sh,
#      the throwing callback crashed the app here (std::terminate). iOS still
#      reports it as "Non-js exception: ..." where desktop says "Error: ...":
#      jsi::JSError thrown inside hermesvm.framework is not matched as the
#      engine's own jsi::JSError (a separate defect, docs/eng/ios-platform.md).
#   R  the 2 s rAF loop runs at frame rate (20..150/s)
#   F  frame-paced: the engine reports mode=frame, its flushes come from frames
#      (frame_flushes > 0, timer_flushes == 0), and there were no more flushes
#      than presented frames. Rate alone cannot tell the two cadences apart:
#      the timer fallback also runs about 60/s.
# Pass line: IOS_RAF_PASS (rate=<n>/s frame_flushes=<n> timer_flushes=0).
# Mutants: tools/mutation-verify-ios-raf.sh.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
ios_begin ios-raf
FAILS=()
bad() { echo "IOS_RAF_GATE FAIL $1: $2"; FAILS+=("$1"); }

bash tools/engine-build-ios.sh simulator > "$IOS_WORK/engine-build.log" 2>&1 \
  || { tail -25 "$IOS_WORK/engine-build.log"; echo "IOS_RAF_FAIL (engine build)"; exit 1; }
ios_build_testhost engine || { echo "IOS_RAF_FAIL (test host build)"; exit 1; }
ios_sim_up || { echo "IOS_RAF_FAIL (simulator)"; exit 1; }

LOG="$IOS_WORK/app.log"
ios_launch "$LOG" engine --bundle=native-anim-dots.jsbundle --app=RafSemantics --log-raf=1 \
  || { echo "IOS_RAF_FAIL (launch)"; exit 1; }
ios_wait_log "$LOG" 'rafrate per_s=' 40 || bad R "the 2 s rAF loop never finished: $(tail -2 "$LOG" | tr '\n' ' ')"
# One more counters line after the loop ended (logged every 60 frames).
N=$(grep -c 'testhost: engine raf_pacing' "$LOG"); ios_wait_log "$LOG" 'testhost: engine raf_pacing' 1
for _ in 1 2 3 4 5 6 7 8; do [ "$(grep -c 'testhost: engine raf_pacing' "$LOG")" -gt "$N" ] && break; sleep 0.5; done
cat "$LOG.err" >> "$LOG" 2> /dev/null
grep -E 'rafsem|rafrate|js-exception|engine raf_pacing|engine presented=' "$LOG" | tail -6
ios_keep "$LOG"

echo "== C: contract =="
grep -q 'rafsem a=1 b=0 c=1 d=0 nested_later=1' "$LOG" \
  || bad C "$(grep -m1 'rafsem' "$LOG" || echo 'no rafsem line') (want a=1 b=0 c=1 d=0 nested_later=1)"
grep -q 'js-exception.*raf-semantics expected throw' "$LOG" || bad C "a throwing rAF callback was swallowed, not reported"

echo "== R: rate =="
RATE=$(sed -nE 's/.*rafrate per_s=([0-9]+).*/\1/p' "$LOG" | tail -1)
echo "rAF ${RATE:-?}/s"
[ -n "$RATE" ] && [ "$RATE" -ge 20 ] && [ "$RATE" -le 150 ] || bad R "rAF ran ${RATE:-?}/s, want frame rate (20..150)"

echo "== F: frame-paced =="
SUM=$(grep 'testhost: engine raf_pacing' "$LOG" | tail -1 | sed 's/.*engine //')
PRES=$(sed -nE 's/.*testhost: engine presented=([0-9]+).*/\1/p' "$LOG" | tail -1)
field() { echo "$SUM" | sed -nE "s/.* $1=([0-9a-z]+).*/\1/p"; }
echo "${SUM:-no counters} (presented ${PRES:-?})"
[ "$(field mode)" = frame ] || bad F "mode is '$(field mode)', not frame"
[ "${SUM:-}" != "" ] && [ "$(field frame_flushes)" -gt 0 ] 2> /dev/null || bad F "no frame-driven flush"
[ "$(field timer_flushes)" = 0 ] || bad F "timer_flushes=$(field timer_flushes): rAF ran on the timer fallback"
[ -n "$PRES" ] && [ "$(field frame_flushes)" -le "$((PRES + 60))" ] 2> /dev/null \
  || bad F "frame_flushes=$(field frame_flushes) exceeds the frames presented (${PRES:-?})"

[ "${#FAILS[@]}" = 0 ] || { echo "IOS_RAF_FAIL (${FAILS[*]})"; exit 1; }
echo "IOS_RAF_PASS (rate=${RATE}/s frame_flushes=$(field frame_flushes) timer_flushes=0)"
