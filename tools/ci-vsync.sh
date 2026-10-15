#!/usr/bin/env bash
# FP-11 GATE: frames are requested, deduped and paced by a vsync source.
#
# fixtures/fp11-vsync, windowed under xvfb with the default idle-skip loop and
# --vsync-log (one line per accepted frame request and per present, stamped on
# the engine's steady clock). xvfb never blocks in the swap, so this exercises
# the FrameScheduler's swap-duration probe and its software 60 Hz clock.
#   A  pacing: VsyncSpin (endless native-driven slide), 120 present intervals
#      after the source decision; median over 3 runs of the mean within 5% of
#      the period and of the stddev under 10% of it. Control arm: a 60 Hz
#      sleep-to-grid ticker doing 1 ms of CPU work per tick
#      (tools/vsync_control.py) runs beside each spin run; its median interval
#      stddev is the box's preemption noise right then and is added to the 10%
#      allowance (~0.1 ms on a quiet box, 1-2 ms at load 20+ on 22 cores, where
#      llvmpipe draws alone reach a 5-11 ms p99).
#   B  one frame per vsync: in every run at most 1 interval under half a period
#      and frame_scheduler max_frames_per_tick=1
#   C  idle: VsyncIdle (static) presents 0 frames in a 2 s window once settled
#   D  mutation: VsyncMutate changes a colour 1 s after mount; the first present
#      lands within 2 periods of the damage request, at most 2 presents serve it,
#      and nothing presented while idle before it
# Node-free: committed bundle + RNI_BIN. tools/vsync_check.py does the maths.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/fp11-vsync/prebuilt/fp11-vsync.bundle"
fail() { echo "VSYNC FAIL: $*" >&2; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
[ "$(uname -s)" = Linux ] || fail "linux only (xvfb); darwin/win32 lanes come with FP-19"
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
else
  bash tools/engine-build.sh linux x64 > "${TMPDIR:-/tmp}/ci-vsync-build.log" 2>&1 \
    || { tail -20 "${TMPDIR:-/tmp}/ci-vsync-build.log" >&2; fail "engine build failed"; }
  BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
echo "engine: $BIN ($(sha256sum "$BIN" | cut -c1-12))"

WORK="$(mktemp -d)"
cleanup() { [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

run() {  # app tag run_sec
  local app="$1" tag="$2" sec="$3" rc=0
  ( cd "$(dirname "$BIN")" && timeout 120 \
      xvfb-run -a -s "-screen 0 1280x1024x24" "$BIN" --window --scale 1 \
      --width 400 --height 300 --bundle "$BUNDLE" --app-name "$app" \
      --probe-banner off --supersample-rnsvg 0 --idle-skip --idle-run-sec "$sec" \
      --vsync-log ) > "$WORK/$tag.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$WORK/$tag.log" || fail "$tag: nothing mounted"
  grep -q '^rn-impeller: supersample_rnsvg=0' "$WORK/$tag.log" || fail "$tag: supersample_rnsvg is not 0"
  grep -h 'gl_validation_errors\|frame_scheduler' "$WORK/$tag.log" || true
}

echo "== render =="
for i in 1 2 3; do
  python3 tools/vsync_control.py 4.5 "$WORK/control-$i.txt" &
  CTRL=$!
  run VsyncSpin "spin-$i" 3.5
  wait "$CTRL" || fail "control ticker $i failed"
done
run VsyncIdle idle 3.2
run VsyncMutate mutate 2.5

echo "== check =="
if python3 tools/vsync_check.py "$WORK"; then
  echo "VSYNC PASS"
else
  exit 1
fi
