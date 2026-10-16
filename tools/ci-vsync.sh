#!/usr/bin/env bash
# FP-11 GATE: frames are requested, deduped and paced by a vsync source.
#
# fixtures/fp11-vsync, windowed under xvfb with the default idle-skip loop and
# --vsync-log (one line per accepted frame request and per present, stamped on
# the engine's steady clock). xvfb never blocks in the swap, so this exercises
# the FrameScheduler's swap-duration probe and its software 60 Hz clock.
#   A  pacing: VsyncSpin (endless native-driven slide), 120 present intervals
#      after the source decision; median over 3 runs of the mean within 5% of
#      the period (plus the control's own drift from it) and of the stddev
#      under 10% of it plus 1.5x the control's stddev. Control arm: a 60 Hz
#      sleep-to-grid ticker (tools/vsync_control.py) runs beside each spin run
#      doing the engine's OWN frame cost per tick, measured by a calibration
#      run (spin-0) of the same binary under the same load (FP-06): its
#      interval stats are the box's preemption noise right then.
#   B  one frame per vsync: in every run no two presents serve the same vsync
#      tick (tick = t_us - since_vsync_us, exact) and frame_scheduler
#      max_frames_per_tick=1; pooled over the 3 runs, intervals under half a
#      period number at most 3 + 2x the control arms' (a late frame followed by
#      an on-time one is short without being a double)
#   C  idle: VsyncIdle (static) presents 0 frames in a 2 s window once settled
#   D  mutation: VsyncMutate changes a colour 1 s after mount; the first present
#      lands within 2 periods of the damage request, at most 2 presents serve it,
#      and nothing presented while idle before it
# Node-free: committed bundle + RNI_BIN. tools/vsync_check.py does the maths.
# VSYNC_ARMS (FP-26, opt-in): space-separated subset of "A B C D tick"; default
# "A B C D" (every arm). `tick` is B's exact per-run half alone (shared_tick=0,
# max_frames_per_tick=1), without B's load-relative short-interval count. Without
# A or B the control tickers are skipped (spin-0 still runs as the warm-up).
# tools/ci-vsync-sched.sh runs "tick C D" (darwin on ANGLE-Metal, see there).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/fp11-vsync/prebuilt/fp11-vsync.bundle"
fail() { echo "VSYNC FAIL: $*" >&2; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
. tools/lib/host-window.sh
# darwin (FP-19): real window server, no xvfb; run it on the Mac itself.
[ "$(rni_host)" != other ] || fail "linux (xvfb) or darwin only"
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
else
  bash tools/engine-build.sh linux x64 > "${TMPDIR:-/tmp}/ci-vsync-build.log" 2>&1 \
    || { tail -20 "${TMPDIR:-/tmp}/ci-vsync-build.log" >&2; fail "engine build failed"; }
  BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
# FP-57: under tools/ci-sanitize.sh (RNI_BUDGETS_FUNCTIONAL_ONLY=1, sanitizer builds only) the default
# swaps B for `tick`: B's exact one-frame-per-vsync half stays, its load-relative short-interval
# count (allowed 3 + 2x control) is a statistic ASan's frame jitter trips at load 0.6; A keeps
# its paced-mean check and drops the jitter sd budget, D still needs 1-2 presents for the mutation
# and none while idle but drops the 2-period latency budget (tools/vsync_check.py).
if [ "${RNI_BUDGETS_FUNCTIONAL_ONLY:-0}" = 1 ]; then
  "$BIN" --help 2>/dev/null | grep -q '^rn-impeller: sanitize_build=1 ' \
    || fail "RNI_BUDGETS_FUNCTIONAL_ONLY=1 needs a sanitizer build (no sanitize_build=1 from $BIN --help)"
  VSYNC_ARMS="${VSYNC_ARMS:-A tick C D}"
fi
VSYNC_ARMS="${VSYNC_ARMS:-A B C D}"
export VSYNC_ARMS
CONTROL=0
for a in $VSYNC_ARMS; do
  case "$a" in A|B) CONTROL=1 ;; C|D|tick) ;; *) fail "unknown VSYNC_ARMS entry '$a' (want A B C D tick)" ;; esac
done
echo "arms: $VSYNC_ARMS"
echo "engine: $BIN ($(shasum -a 256 "$BIN" | cut -c1-12)) host=$(rni_host)"

WORK="$(mktemp -d)"
cleanup() { [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

run() {  # app tag run_sec
  local app="$1" tag="$2" sec="$3" rc=0
  ( cd "$(dirname "$BIN")" && rni_xrun "$WORK/xvfb.auth" timeout 120 "$BIN" --window --scale 1 \
      --width 400 --height 300 --bundle "$BUNDLE" --app-name "$app" \
      --probe-banner off --supersample-rnsvg 0 --idle-skip --idle-run-sec "$sec" \
      --vsync-log ) > "$WORK/$tag.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$WORK/$tag.log" || fail "$tag: nothing mounted"
  grep -q '^rn-impeller: supersample_rnsvg=0' "$WORK/$tag.log" || fail "$tag: supersample_rnsvg is not 0"
  grep -h 'gl_validation_errors\|frame_scheduler' "$WORK/$tag.log" || true
}

echo "== render =="
# FP-06: calibrate the control arm. The control ticker's per-tick work is this
# binary's own median vsync-to-present time (the frame's wall cost: tick, build,
# raster, swap) measured right now under whatever load the box has, so a
# sanitized binary on a busy box is judged against noise of the same size as
# its frames, not against a 1 ms stand-in. (build_p50 + raster_p50 read ~1 ms
# even under ASan: llvmpipe's GL work runs after the CPU-side encode.)
# spin-0 is also every mode's cold-start warm-up: without it the first scored
# run on a loaded Mac spent ~2 s of its 3.5 s starting up (78 frames, FP-26).
run VsyncSpin spin-0 1.5
if [ "$CONTROL" = 1 ]; then
  # FP-27: darwin Metal logs presents at their displayed time (source=displaylink), so
  # since_vsync_us there includes the compositor's latency; the frame's wall cost is
  # its tick-to-encode time from the vsync_displayed line instead.
  WORK_US="$( { grep -v 'source=auto$' "$WORK/spin-0.log" | grep -v 'source=displaylink$' \
      | sed -n 's/^rn-impeller: vsync_present .* since_vsync_us=\([0-9]*\) source=[a-z]*$/\1/p' || true
    sed -n 's/^rn-impeller: vsync_displayed n=[0-9]* presented_us=[1-9][0-9]* encode_us=\([0-9]*\) tick_us=\([0-9]*\) .*/\1 \2/p' "$WORK/spin-0.log" \
      | awk '{ print $1 - $2 }'; } \
    | sort -n | awk '{ v[NR] = $1 } END { if (NR < 10) exit; w = v[int((NR + 1) / 2)]; if (w < 1000) w = 1000; if (w > 12000) w = 12000; print w }')"
  [ -n "$WORK_US" ] || fail "calibration run printed fewer than 10 paced vsync_present lines"
  echo "control work per tick: ${WORK_US}us (spin-0 median vsync-to-present, or tick-to-encode on displaylink)"
  echo "$WORK_US" > "$WORK/control-work.txt"
  for i in 1 2 3; do
    python3 tools/vsync_control.py 4.5 "$WORK/control-$i.txt" "$WORK_US" &
    CTRL=$!
    run VsyncSpin "spin-$i" 3.5
    wait "$CTRL" || fail "control ticker $i failed"
  done
else
  # scheduler arms only: the spin runs still feed `tick` (every run's read-back)
  for i in 1 2 3; do run VsyncSpin "spin-$i" 3.5; done
fi
run VsyncIdle idle 3.2
run VsyncMutate mutate 2.5

echo "== check =="
if python3 tools/vsync_check.py "$WORK"; then
  echo "VSYNC PASS"
else
  exit 1
fi
