#!/usr/bin/env bash
# Wayland touch drag-to-scroll gate: REAL wl_touch from a compositor scrolls a
# ScrollView. ci-touch-scroll.sh proves the gesture through the synthetic
# t* hook; this drives the touchscreen path end to end: headless Weston +
# kiosk-shell, rni-touch-inject feeding libweston's touch input, the engine's
# wl_touch listener (host/WaylandTouch.cpp), then GlfwSurface::synthesiseTouch.
# The drags use drag.js's shape from the board: 20 steps, 30 ms apart, lifted
# 30 ms after the last step.
#
#   V  vertical list, finger 500 -> 100: begin-drag at y=0, end-drag at y=390
#      (400 pt minus the 10 pt slop), then a fling past it.
#   H  paged pager, finger 850 -> 450: end-drag at x=390, settles on x=600.
#   T  a tap at (150,50) after the fling presses the row now under it.
#   N  same binary, same touches, RNI_WAYLAND_TOUCH=0: nothing scrolls.
#
# Usage: bash tools/ci-wayland-touch-scroll.sh [--arch x64|arm64]   (default x64)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ARCH=x64
case "${1:-}" in
  --arch) ARCH="${2:-}" ;;
  --arch=*) ARCH="${1#*=}" ;;
  "") ;;
  *) echo "usage: $0 [--arch x64|arm64]" >&2; exit 2 ;;
esac
case "$ARCH" in
  x64) IMG="${RNI_X64_IMAGE:-rni-x64-tools:noble}"; RUN_SEC=16 ;;
  arm64) IMG="${RNI_ARM64_IMAGE:-rni-arm64-tools:bookworm}"; RUN_SEC=60 ;;
  *) echo "usage: $0 [--arch x64|arm64]" >&2; exit 2 ;;
esac
export RNI_TEST_ARCH="$ARCH"
fail() { echo "WAYLAND_TOUCH_SCROLL_FAIL: $*"; exit 1; }
BUNDLE="$ROOT/fixtures/touch-scroll/prebuilt/touch-scroll.bundle"
[ -f "$BUNDLE" ] || fail "no prebuilt bundle (bash tools/build-fixture-bundle.sh touch-scroll TouchScrollFixture)"
docker image inspect "$IMG" > /dev/null 2>&1 || fail "no $IMG image (see tools/ci-arm64-wayland-touch.sh)"
WORK="$(mktemp -d)"
trap '[ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"' EXIT

# drag T0 X0 Y0 X1 Y1 -> "T0:down X0 Y0;...;T:up", 20 moves 30 ms apart.
drag() {
  local t="$1" x0="$2" y0="$3" x1="$4" y1="$5" i s
  s="$t:down $x0 $y0"
  for ((i = 1; i <= 20; i++)); do
    s+=";$((t + 30 * i)):move $((x0 + (x1 - x0) * i / 20)) $((y0 + (y1 - y0) * i / 20))"
  done
  echo "$s;$((t + 630)):up"
}
SCRIPT="$(drag 2000 150 500 150 100);$(drag 6000 850 200 450 200);10000:down 150 50;10100:up"
ARGS=(--window --prewarm off --bundle "$BUNDLE" --app-name TouchScrollFixture
      --width 1000 --height 700 --probe-banner off --idle-skip --idle-run-sec "$RUN_SEC")

run() {  # $1 = arm dir; env passes through
  set +e
  timeout 300 bash tools/arm64-wayland-run.sh "$WORK/$1" 1000 700 "$SCRIPT" -- "${ARGS[@]}" > /dev/null 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$WORK/$1/engine.out"; fail "$1: engine exited $rc"; }
  grep -q 'glfw_platform=wayland' "$WORK/$1/engine.out" || fail "$1: GLFW did not run on Wayland"
  local injected; injected=$(grep -c 'rni-touch-inject: \(down\|up\|move\)' "$WORK/$1/weston.log" || true)
  [ "$injected" -ge 45 ] || fail "$1: Weston injected only $injected of 45 events (instrument broken)"
}
js() { grep -E "^\[js\] $2" "$1" || true; }
last() { sed -n "s/^\[js\] $2 [xy]=\(-\{0,1\}[0-9]*\)\$/\1/p" "$1" | tail -1; }
show() { { grep -E '^\[js\] [A-Z_]+ |touch_scroll|wl_touch (down|up)' "$1" | grep -v '_SCROLL [xy]=' | sed 's/^/   /'; } || true; }

echo "== $ARCH: positive run (wl_touch listener attached) =="
run pos
P="$WORK/pos/engine.out"
grep -q 'wayland_touch attached seat=1 touch=1' "$P" || fail "listener did not bind wl_touch"
[ -n "$(js "$P" 'V_BEGIN_DRAG y=0$')" ] || { show "$P"; fail "V: no onScrollBeginDrag from a real wl_touch drag"; }
[ "$(last "$P" V_END_DRAG)" = "390" ] || { show "$P"; fail "V: onScrollEndDrag not at y=390"; }
V_END="$(last "$P" V_MOMENTUM_END)"
[ -n "$V_END" ] && [ "$V_END" -gt 440 ] || { show "$P"; fail "V: no fling past y=390 after a moving lift (got '${V_END:-none}')"; }
[ "$(last "$P" H_END_DRAG)" = "390" ] || { show "$P"; fail "H: pager onScrollEndDrag not at x=390"; }
[ "$(last "$P" H_MOMENTUM_END)" = "600" ] || { show "$P"; fail "H: pager did not settle on x=600"; }
ROW=$(( (50 + V_END) / 100 ))
[ "$(js "$P" 'ROW_PRESS ' | tail -1)" = "[js] ROW_PRESS $ROW" ] \
  || { show "$P"; fail "T: a tap at y=50 over offset $V_END should press row $ROW"; }
[ "$(js "$P" 'ROW_PRESS ' | wc -l)" = "1" ] || { show "$P"; fail "T: a drag also pressed a row"; }
echo "   V pass (end-drag 390, fling to $V_END); H pass (390 -> 600); T pass (row $ROW)"

echo "== $ARCH: negative run (RNI_WAYLAND_TOUCH=0, same binary, same touches) =="
RNI_WAYLAND_TOUCH=0 run neg
N="$WORK/neg/engine.out"
grep -q 'wayland_touch disabled' "$N" || fail "N: negative arm did not disable the listener"
[ -z "$(js "$N" '[VH]_BEGIN_DRAG')" ] || fail "N: a scroll began with the listener off"
echo "   N pass (no wl_touch, no scroll)"
echo "WAYLAND_TOUCH_SCROLL_PASS ($ARCH: real wl_touch drags scroll the list with a fling and page the pager; taps still press)"
