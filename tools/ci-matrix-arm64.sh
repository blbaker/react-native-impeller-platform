#!/usr/bin/env bash
# M3 board-less proof gate for the linux-arm64 package (the board matrix,
# docs/IMAGE-REQUIREMENTS.md). There is no board: the arm64 engine runs under
# qemu-aarch64 in rni-arm64-tools:bookworm (Debian arm64 userspace, Mesa
# llvmpipe), as a client of headless Weston with kiosk-shell (the board image's
# shell). Each arm judges what the engine itself renders and reports.
#
#   a  rn-core screen (fixtures/rn-core, rncore://image?mode=cover), arm64 on
#      Weston against the x64 package on Weston (rni-x64-tools:noble): whole
#      frame AND one crop per element (tools/ppm_compare.py --crop). Both frames
#      must also pass the fixture's absolute pixel rules (rn_core_check.py
#      image cover), so a defect present in BOTH packages cannot pass by agreeing.
#   b  wl_touch through Weston's own input path (tools/arm64-testenv/
#      rni-touch-inject, as in ci-arm64-wayland-touch.sh) on fixtures/arm64-touch:
#      a tap on tap-b must hit tap-b's TAG (taken from an independent headless
#      layout report, not from the run under test) and fire pressed-tap-b once;
#      a tap on empty space must hit the root view and fire nothing; a tap OFF
#      the output (5000,5000: no surface there) must reach the engine not at all.
#   c  the arm-a screen on the X11 backend: arm64 binary under Xvfb with Weston
#      ALSO up and XDG_SESSION_TYPE=wayland (that layout picks Wayland on its
#      own, ci-arm64-wayland-touch S3), so only RNI_GLFW_PLATFORM=x11 can select
#      X11 (the hint reason must say so). Same whole-frame + per-element rules
#      against the same x64 reference.
#
# Usage: bash tools/ci-matrix-arm64.sh [--arms "a b c"]
# Env:   RNI_ARM64_ENGINE_DIR / RNI_X64_ENGINE_DIR / RNI_ARM64_IMAGE / RNI_X64_IMAGE
#        (tools/arm64-wayland-run.sh), KEEP_WORKDIR=1. Mutants:
#        tools/mutation-verify-matrix-arm64.sh.
# llvmpipe is software: every pixel here proves the arm64 build and packaging,
# nothing about libmali or Panthor (UNVERIFIED-ON-HARDWARE, never PASS).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ARMS="a b c"
while [ $# -gt 0 ]; do
  case "$1" in
    --arms) ARMS="${2:-}"; shift 2 ;;
    --arms=*) ARMS="${1#*=}"; shift ;;
    *) echo "usage: $0 [--arms \"a b c\"]" >&2; exit 2 ;;
  esac
done

# --- thresholds (stated; measured 2026-10-19 on the rn-core screen: arm64
# bookworm Mesa 22.3.6 llvmpipe vs x64 noble llvmpipe = max channel delta 1,
# 520 px at delta 1, all on the band edges of the scaled images B and C) ------
TOL=4             # a pixel differs when any channel differs by MORE than 4 levels
WHOLE_MAX=0.001   # whole frame: at most 0.1% differing (120 of 400x300)
ELEM_MAX=0.005    # each element crop: at most 0.5% of its own pixels differing
# Element crops, x,y,w,h in points (= pixels at --scale 1), from fixtures/rn-core/index.js:
ELEMS=("A_natural_png:10,10,120,168" "B_cover_box:150,10,200,100" "C_card_back:150,120,60,84"
       "BG_right:220,120,170,170" "BG_left:10,185,130,110")
SHOT_FRAMES=60    # capture on the first painted frame >= 60 (anchored to frames, not a clock)

fail() { echo "ARM64_MATRIX_FAIL: $*"; exit 1; }
for img in "${RNI_ARM64_IMAGE:-rni-arm64-tools:bookworm}" "${RNI_X64_IMAGE:-rni-x64-tools:noble}"; do
  docker image inspect "$img" > /dev/null 2>&1 || fail "no $img image (tools/arm64-testenv/Dockerfile.tools / Dockerfile.x64)"
done
RNCORE="$ROOT/fixtures/rn-core/prebuilt/rn-core.bundle"
TOUCH="$ROOT/fixtures/arm64-touch/prebuilt/arm64-touch.bundle"
[ -s "$RNCORE" ] && [ -s "$TOUCH" ] || fail "missing prebuilt bundle(s)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/matrix-arm64.XXXXXX")"
trap '[ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"' EXIT

# wl <arch> <dir> <W> <H> <touch-script> <engine args...>: one session (env passes through)
wl() {
  local arch="$1" dir="$2" w="$3" h="$4" script="$5" rc=0; shift 5
  RNI_TEST_ARCH="$arch" timeout 420 bash tools/arm64-wayland-run.sh "$WORK/$dir" "$w" "$h" "$script" -- "$@" \
    > /dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$dir/engine.out" 2>/dev/null; fail "$dir: engine exited $rc"; }
}

# screen <arch> <dir> <platform> <idle-sec>: the rn-core screen, captured from the engine
screen() {
  local arch="$1" dir="$2" plat="$3" idle="$4" o
  wl "$arch" "$dir" 400 300 "" --window --prewarm off --bundle "$RNCORE" --app-name RnCore \
    --width 400 --height 300 --scale 1 --supersample-rnsvg 0 --probe-banner off \
    --initial-url 'rncore://image?mode=cover' --idle-skip --idle-run-sec "$idle" \
    --screenshot "$WORK/$dir/shot.ppm" --screenshot-after-frames "$SHOT_FRAMES"
  o="$WORK/$dir/engine.out"
  grep -q "glfw_platform=$plat\$" "$o" || fail "$dir: expected glfw_platform=$plat, got $(grep -o 'glfw_platform=[a-z0-9]*' "$o" | head -1)"
  [ -s "$WORK/$dir/shot.ppm" ] || fail "$dir: no capture (no 'screenshot=' line)"
  # The capture must come after all three images loaded, or it compares a half-loaded screen.
  local loads shot
  loads="$(grep -n 'RNCORE_IMAGE onLoad' "$o" | tail -1 | cut -d: -f1)"
  shot="$(grep -n 'rn-impeller: screenshot=' "$o" | head -1 | cut -d: -f1)"
  [ "$(grep -c 'RNCORE_IMAGE onLoad' "$o")" -eq 3 ] && [ -n "$shot" ] && [ "$loads" -lt "$shot" ] \
    || fail "$dir: capture taken before the 3 images loaded (onLoad lines $(grep -c 'RNCORE_IMAGE onLoad' "$o"))"
  python3 tools/rn_core_check.py image "$WORK/$dir/shot.ppm" cover > "$WORK/$dir/abs.check" 2>&1 \
    || { tail -5 "$WORK/$dir/abs.check"; fail "$dir: the fixture's absolute pixel rules fail"; }
}

# compare <label> <test.ppm>: against the x64 reference, whole frame + each element
compare() {
  local label="$1" t="$2" bad="" line n frac
  line="$(python3 tools/ppm_compare.py "$REF" "$t" --tol "$TOL" --side-png "$WORK/$label-side.png")"
  echo "   $label whole: ${line#PPM_COMPARE }"
  frac="$(sed -n 's/.* frac=\([0-9.]*\) .*/\1/p' <<< "$line")"
  awk -v f="$frac" -v m="$WHOLE_MAX" 'BEGIN { exit !(f <= m) }' || bad="$bad whole($frac>$WHOLE_MAX)"
  for e in "${ELEMS[@]}"; do
    n="${e%%:*}"
    line="$(python3 tools/ppm_compare.py "$REF" "$t" --tol "$TOL" --crop "${e#*:}")"
    frac="$(sed -n 's/.* frac=\([0-9.]*\) .*/\1/p' <<< "$line")"
    echo "   $label $n: ${line#PPM_COMPARE size=400x300 }"
    awk -v f="$frac" -v m="$ELEM_MAX" 'BEGIN { exit !(f <= m) }' || bad="$bad $n($frac>$ELEM_MAX)"
  done
  [ -z "$bad" ] || fail "$label: arm64 render differs from x64 beyond the stated thresholds:$bad (side-by-side: $WORK/$label-side.png)"
}

REF=""
reference() {  # the x64 package on Weston 13 (noble), once per run
  [ -n "$REF" ] && return 0
  echo "== x64 reference: same screen, x64 package on Weston (rni-x64-tools:noble) =="
  screen x64 ref wayland 6
  REF="$WORK/ref/shot.ppm"
  echo "   reference ok (absolute rules pass, $(grep -o 'screenshot=.*' "$WORK/ref/engine.out" | sed 's/.* frame=/frame=/'))"
}

arm_a() {
  reference
  echo "== a: arm64 (qemu) on Weston + kiosk-shell, same screen =="
  screen arm64 a wayland 15
  echo "   $(grep -o 'first_present_ms=[0-9]*' "$WORK/a/engine.out" | head -1), $(grep -o 'GL_RENDERER=.*' "$WORK/a/engine.out" | head -1)"
  compare a "$WORK/a/shot.ppm"
  echo "   a pass"
}

arm_b() {
  echo "== b: wl_touch on fixtures/arm64-touch (arm64, qemu) =="
  # Oracle: tags from the x64 package's HEADLESS layout report, not from the run under test.
  local x64bin="${RNI_X64_ENGINE_DIR:-$ROOT/packages-engine/engine-linux-x64/bin}/rn-impeller" rep tb tr o
  rep="$WORK/b-layout.txt"
  "$x64bin" --headless --probe-banner off --bundle "$TOUCH" --app-name Arm64Touch \
    --width 600 --height 400 --frames 2 > "$rep" 2>&1 || fail "b: headless layout report failed"
  tb="$(sed -n 's/^rn-impeller: node_frame=View,\([0-9]*\),200\.0,0\.0,200\.0,100\.0$/\1/p' "$rep")"
  tr="$(sed -n 's/^rn-impeller: node_frame=View,\([0-9]*\),0\.0,0\.0,600\.0,400\.0$/\1/p' "$rep")"
  [ "$(wc -w <<< "$tb")" = 1 ] && [ "$(wc -w <<< "$tr")" = 1 ] || fail "b: layout report has no unique tap-b / root view (tap-b='$tb' root='$tr')"
  echo "   oracle (x64 headless node_frame): tap-b tag=$tb, root view tag=$tr"
  wl arm64 b 600 400 "2000:down 300 50;2150:up;3500:down 300 350;3650:up;5000:down 5000 5000;5150:up" \
    --window --prewarm off --bundle "$TOUCH" --app-name Arm64Touch --width 600 --height 400 \
    --probe-banner off --idle-skip --idle-run-sec 14
  o="$WORK/b/engine.out"
  grep -q 'glfw_platform=wayland$' "$o" || fail "b: GLFW did not run on Wayland"
  grep -q 'wayland_touch attached seat=1 touch=1' "$o" || fail "b: the touch listener did not bind wl_touch"
  [ "$(grep -c 'rni-touch-inject: \(down\|up\)' "$WORK/b/weston.log")" -eq 6 ] \
    || fail "b: Weston injected $(grep -c 'rni-touch-inject: \(down\|up\)' "$WORK/b/weston.log") of 6 events (instrument broken)"
  grep -q 'rni-touch-inject: down 5000 5000' "$WORK/b/weston.log" || fail "b: the off-output tap was never injected"
  grep 'touch_down hit=\|alert=' "$o" | sed 's/^/   /'
  local hits; hits="$(grep -o 'touch_down hit=[0-9]* at=[0-9.,]*' "$o" | tr '\n' ' ')"
  [ "$(grep -c 'touch_down hit=' "$o")" -eq 2 ] || fail "b: expected 2 touch_down lines (tap-b, empty space), got: $hits"
  grep -q "touch_down hit=$tb at=300.0,50.0" "$o" || fail "b: the tap at (300,50) did not hit tap-b's tag $tb: $hits"
  grep -q "touch_down hit=$tr at=300.0,350.0" "$o" || fail "b: the tap on empty space (300,350) did not hit the root view $tr: $hits"
  [ "$(grep -c 'alert=pressed-tap-b' "$o")" -eq 1 ] && [ "$(grep -c 'alert=' "$o")" -eq 1 ] \
    || fail "b: expected exactly one alert (pressed-tap-b), got: $(grep -o 'alert=[a-z0-9-]*' "$o" | tr '\n' ' ')"
  [ "$(grep -c 'wl_touch down' "$o")" -eq 2 ] || fail "b: the engine saw $(grep -c 'wl_touch down' "$o") wl_touch downs; the off-output tap must deliver none"
  grep -q 'wayland_touch downs=2 moves=0 ups=2' "$o" || fail "b: listener counts wrong: $(grep 'wayland_touch downs=' "$o")"
  echo "   b pass (tap-b -> tag $tb + pressed-tap-b; empty -> root $tr, no alert; off-output -> nothing)"
}

arm_c() {
  reference
  echo "== c: same screen on X11 (arm64, Xvfb, Weston also up, XDG_SESSION_TYPE=wayland, RNI_GLFW_PLATFORM=x11) =="
  RNI_SESSION_X11=1 RNI_SESSION_TYPE=wayland RNI_GLFW_PLATFORM=x11 screen arm64 c x11 15
  grep -q 'glfw_platform_hint=x11 reason=RNI_GLFW_PLATFORM$' "$WORK/c/engine.out" \
    || fail "c: X11 was not selected by RNI_GLFW_PLATFORM: $(grep -o 'glfw_platform_hint=.*' "$WORK/c/engine.out")"
  compare c "$WORK/c/shot.ppm"
  echo "   c pass"
}

for a in $ARMS; do
  case "$a" in a) arm_a ;; b) arm_b ;; c) arm_c ;; *) fail "unknown arm $a" ;; esac
done
echo "ARM64_MATRIX_PASS arms=\"$ARMS\" (qemu-aarch64 + llvmpipe; tol $TOL, whole <= $WHOLE_MAX, element <= $ELEM_MAX; libmali/Panthor UNVERIFIED-ON-HARDWARE)"
