#!/usr/bin/env bash
# FP-10 GATE: a native-driven Animated.timing keeps tracking its curve while
# the JS thread is busy, because NativeAnimated ticks on the frame-loop thread.
#
# fixtures/native-anim-jsstall, windowed under xvfb, RNI_TEST_ANIM_ROW=150 so
# every present prints the red box's left edge (read back from the frame) and
# the animation clock. The slide is 2 px per clock frame, so
# lag = clock - x0/2 (frames), relative to the run's least-lag sample.
# (tools/native_anim_jsstall_check.py)
#   A  lag: median over 3 runs of the stall arm's max lag (JS busy-loops 50 ms
#      on every other rAF) <= median of the zero-stall control + 1 frame
#   B  cadence: during the slide every present advances the clock by 1 and the
#      box by 2 px (>= 95% of present pairs, every run)
#   C  the stall was real: >= 2 "jsstall n=" lines inside the slide in every
#      stall run, none in the control; the slide reaches x0=320
#   D  native Animated.event: a wheel scroll at frame 20 moves the box driven
#      by onScroll (useNativeDriver) from x0=0 to x0=200
# Frame-counted, not wall-clock: xvfb has no vsync, so one clock frame is the
# vsync unit (FP-01). Node-free: committed bundle + RNI_BIN.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/native-anim-jsstall/prebuilt/native-anim-jsstall.bundle"
fail() { echo "NAJ_FAIL: $*" >&2; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
. tools/lib/host-window.sh
# darwin (FP-19): real window server, no xvfb; run it on the Mac itself.
[ "$(rni_host)" != other ] || fail "linux (xvfb) or darwin only"
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
else
  bash tools/engine-build.sh linux x64 > "${TMPDIR:-/tmp}/ci-naj-build.log" 2>&1 \
    || { tail -20 "${TMPDIR:-/tmp}/ci-naj-build.log" >&2; fail "engine build failed"; }
  BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
echo "engine: $BIN ($(shasum -a 256 "$BIN" | cut -c1-12)) host=$(rni_host)"

WORK="$(mktemp -d)"
cleanup() { [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

run() {  # app tag frames [extra args...]
  local app="$1" tag="$2" frames="$3" rc=0; shift 3
  ( cd "$(dirname "$BIN")" && RNI_TEST_ANIM_ROW=150 rni_xrun "$WORK/xvfb.auth" timeout 180 "$BIN" --window --scale 1 \
      --width 400 --height 300 --bundle "$BUNDLE" --app-name "$app" \
      --probe-banner off --supersample-rnsvg 0 --frames "$frames" "$@" ) \
    > "$WORK/$tag.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$WORK/$tag.log" || fail "$tag: nothing mounted"
  grep -q '^rn-impeller: supersample_rnsvg=0' "$WORK/$tag.log" || fail "$tag: supersample_rnsvg is not 0"
  grep -h 'gl_validation' "$WORK/$tag.log" || true
}

echo "== render =="
for i in 1 2 3; do
  run NativeSlideStall "stall-$i" 320
  run NativeSlideControl "control-$i" 320
done
run NativeScrollEvent scroll 80 --scroll-after-frames 20:200,100,0,-5

python3 tools/native_anim_jsstall_check.py "$WORK"
