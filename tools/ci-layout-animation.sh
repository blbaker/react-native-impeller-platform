#!/usr/bin/env bash
# FP-40 gate: LayoutAnimation.configureNext animates on the platform thread.
#
# fixtures/fp40-layout-animation (committed prebuilt bundle, node-free), windowed under xvfb. Each
# present reads back row 50 (bar A's right edge) and pixel 200,190 (box B's opacity). Arms:
#   paced x3   Fp40LayoutAnim, --frames 260 --vsync auto (software 60 Hz clock): the update (width
#              60 -> 360), create (opacity 0 -> 1) and delete (opacity 1 -> 0) arms each show >= 10
#              intermediate frames, move monotonically, land on the final layout, and follow RN's
#              easeInEaseOut curve against the KFM's own clock (median of the 3 runs' max error).
#   idle-skip  same app on the real-app loop (--idle-skip, frames=0): the animation must wake a
#              sleeping loop and keep it ticking (onAnimationStarted wake + the clock request).
#   control    Fp40Snap: the same changes without configureNext snap in one frame (0 intermediate),
#              so the detector cannot count a snap or a slow mount as an animation.
# Rebuild the bundle: tools/build-fixture-bundle.sh fp40-layout-animation Fp40LayoutAnim
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/fp40-layout-animation/prebuilt/fp40-layout-animation.bundle"
fail() { echo "LAYOUT_ANIM_FAIL: $*" >&2; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
[ "$(uname -s)" = Linux ] || fail "linux only (xvfb)"
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
else
  bash tools/engine-build.sh linux x64 > "${TMPDIR:-/tmp}/ci-layout-anim-build.log" 2>&1 \
    || { tail -20 "${TMPDIR:-/tmp}/ci-layout-anim-build.log" >&2; fail "engine build failed"; }
  BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
echo "engine: $BIN ($(sha256sum "$BIN" | cut -c1-12))"

WORK="$(mktemp -d)"
cleanup() { [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

run() {  # app tag [extra args...]
  local app="$1" tag="$2" rc=0; shift 2
  ( cd "$(dirname "$BIN")" && RNI_LAYOUT_ANIM_LOG=1 RNI_TEST_ANIM_ROW=50 RNI_TEST_ANIM_PIXEL=200,190 \
      timeout 180 xvfb-run -a -s "-screen 0 1280x1024x24" "$BIN" --window --scale 1 \
      --width 400 --height 300 --bundle "$BUNDLE" --app-name "$app" \
      --probe-banner off --supersample-rnsvg 0 "$@" ) > "$WORK/$tag.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$WORK/$tag.log" || fail "$tag: nothing mounted"
  grep -q '^rn-impeller: supersample_rnsvg=0' "$WORK/$tag.log" || fail "$tag: supersample_rnsvg is not 0"
  grep -h 'gl_validation\|layout_animation started' "$WORK/$tag.log" || true
}

echo "== render =="
for i in 1 2 3; do
  run Fp40LayoutAnim "paced-$i" --frames 260 --vsync auto
done
run Fp40LayoutAnim idle --idle-skip --idle-run-sec 3.5
run Fp40Snap control --frames 260 --vsync auto

echo "== check =="
python3 tools/layout_anim_check.py animated "$WORK/paced-1.log" "$WORK/paced-2.log" "$WORK/paced-3.log" \
  || fail "paced arms"
python3 tools/layout_anim_check.py animated "$WORK/idle.log" || fail "idle-skip arm"
python3 tools/layout_anim_check.py snap "$WORK/control.log" || fail "control arm"
echo "LAYOUT_ANIM_PASS"
