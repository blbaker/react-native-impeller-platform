#!/usr/bin/env bash
# linux Wayland touch gate: a REAL compositor touch reaches JS, on either
# linux package (arm64 under qemu-aarch64, x64 natively).
#
# The engine runs as a Wayland client of headless Weston + kiosk-shell (the
# board image's shell) in the arch's test container. rni-touch-inject puts a
# touch device on a Weston seat and feeds touches through libweston's own
# input path, so the client receives genuine wl_seat/wl_touch protocol events
# — the same ones libinput produces from the board's touch panel.
#
#   A  tap tap-b (300,50)          -> alert=pressed-tap-b, and no other press
#   B  tap empty space (300,350)   -> no alert (the MISS arm: a hit test that
#                                     answers for any coordinate fails here)
#   C  drag 50 -> 300 at y=200     -> alert=drag-right (motion reaches JS)
#   D  tap tap-c (500,50)          -> alert=pressed-tap-c (a second, distinct box)
#   N  same binary, same touches, RNI_WAYLAND_TOUCH=0 (listener not attached):
#      Weston still logs every injected event, and the engine must see NONE.
#      This is GLFW 3.4 on its own, and it is why WaylandTouch.cpp exists.
#   NS Weston with NO input module, so no wl_seat global (a kiosk with
#      require-input=false and nothing plugged in): the engine must reach first
#      present and exit 0 on SIGTERM (--quit-on-term). Stock GLFW 3.4 segfaults
#      in glfwInit here (exit 139; tools/glfw-patches/0001). The seat-less
#      precondition is read from libwayland's own WAYLAND_DEBUG registry trace.
#   X  same binary under Xvfb with no Wayland socket -> glfw_platform=x11 and a
#      first present: the package carries both backends and picks at run time.
#   S1 Weston on the DEFAULT socket (wayland-0, WAYLAND_DISPLAY unset) + Xvfb
#      with DISPLAY set -> x11 (the WSLg layout; host/GlfwPlatformSelect.h)
#   S2 Weston (WAYLAND_DISPLAY set) + Xvfb (DISPLAY set) -> x11
#   S3 as S2 plus XDG_SESSION_TYPE=wayland -> wayland (a declared Wayland session)
#
# Usage: bash tools/ci-arm64-wayland-touch.sh [--arch arm64|x64] [--only-no-seat]   (default arm64)
#        --only-no-seat runs the NS arm alone (tools/mutation-verify-glfw-seat.sh)
# Env:   RNI_ARM64_ENGINE_DIR / RNI_X64_ENGINE_DIR (default packages-engine/engine-linux-<arch>/bin)
#        RNI_ARM64_IMAGE / RNI_X64_IMAGE (see tools/arm64-wayland-run.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ARCH=arm64
ONLY_NS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --arch=*) ARCH="${1#*=}"; shift ;;
    --only-no-seat) ONLY_NS=1; shift ;;
    *) echo "usage: $0 [--arch arm64|x64] [--only-no-seat]" >&2; exit 2 ;;
  esac
done
case "$ARCH" in
  arm64) TAG=ARM64; IMG="${RNI_ARM64_IMAGE:-rni-arm64-tools:bookworm}"; X_SEC=45; S_SEC=12  # qemu: first present ~17 s
         HINT="docker build --platform linux/arm64 -t rni-arm64-tools:bookworm -f tools/arm64-testenv/Dockerfile.tools tools/arm64-testenv" ;;
  x64)   TAG=X64; IMG="${RNI_X64_IMAGE:-rni-x64-tools:noble}"; X_SEC=8; S_SEC=4
         HINT="docker build -t rni-x64-tools:noble -f tools/arm64-testenv/Dockerfile.x64 tools/arm64-testenv" ;;
  *) echo "usage: $0 [--arch arm64|x64]" >&2; exit 2 ;;
esac
export RNI_TEST_ARCH="$ARCH"
fail() { echo "${TAG}_WAYLAND_TOUCH_FAIL: $*"; exit 1; }
BUNDLE="$ROOT/fixtures/arm64-touch/prebuilt/arm64-touch.bundle"
[ -f "$BUNDLE" ] || fail "no prebuilt bundle (bash tools/build-fixture-bundle.sh arm64-touch Arm64Touch)"
docker image inspect "$IMG" >/dev/null 2>&1 || fail "no $IMG image ($HINT)"
WORK="$(mktemp -d)"
trap '[ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"' EXIT
SCRIPT="2000:down 300 50;2150:up;3500:down 300 350;3650:up;5000:down 50 200;5200:move 120 200;5400:move 200 200;5600:move 300 200;5800:up;7000:down 500 50;7150:up"
BASE=(--window --prewarm off --bundle "$BUNDLE" --app-name Arm64Touch --width 600 --height 400
      --probe-banner off --idle-skip)
ARGS=("${BASE[@]}" --idle-run-sec 30)

run() {  # $1 = arm dir; env passes through
  set +e
  timeout 300 bash tools/arm64-wayland-run.sh "$WORK/$1" 600 400 "$SCRIPT" -- "${ARGS[@]}" > /dev/null 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$WORK/$1/engine.out"; fail "$1: engine exited $rc"; }
  grep -q 'glfw_platform=wayland' "$WORK/$1/engine.out" || fail "$1: GLFW did not run on Wayland"
  grep -q 'first_present_ms=' "$WORK/$1/engine.out" || fail "$1: no first present"
  local injected; injected=$(grep -c 'rni-touch-inject: \(down\|up\|move\)' "$WORK/$1/weston.log" || true)
  [ "$injected" -ge 11 ] || fail "$1: Weston injected only $injected of 11 events (instrument broken)"
}

noseat() {
  echo "== $ARCH: no-seat run (Weston with no input module: no wl_seat; SIGTERM after first present) =="
  local o="$WORK/noseat/engine.out" t="$WORK/noseat/touch.log" rc
  set +e
  RNI_SESSION_NO_SEAT=1 RNI_SESSION_TERM_AFTER_MS=3000 WAYLAND_DEBUG=client \
    timeout 300 bash tools/arm64-wayland-run.sh "$WORK/noseat" 600 400 "" -- \
    "${BASE[@]}" --idle-run-sec 200 --quit-on-term > /dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    grep -v 'wl_\|xdg_\|zwp_\|wp_' "$o" 2>/dev/null | tail -8
    [ "$rc" -eq 139 ] && fail "NS: engine exited 139 (SIGSEGV) with no wl_seat: GLFW 3.4 wl_seat_get_version(NULL) in _glfwInitWayland; is tools/glfw-patches/0001 in the build?"
    fail "NS: engine exited $rc with no wl_seat"
  fi
  # The precondition comes from libwayland's own trace, not from the engine.
  # (libwayland < 1.23 prints wl_registry@N, newer wl_registry#N.)
  grep -qE 'wl_registry[@#][0-9]+\.global\([0-9]+, "wl_compositor"' "$o" \
    || fail "NS: no wl_compositor global in the WAYLAND_DEBUG trace (instrument broken)"
  if grep -qE 'wl_registry[@#][0-9]+\.global\([0-9]+, "wl_seat"' "$o"; then
    fail "NS: the compositor advertised a wl_seat: this run is not seat-less"
  fi
  grep -q 'glfw_platform=wayland' "$o" || fail "NS: GLFW did not run on Wayland"
  grep -q 'first_present_ms=' "$o" || fail "NS: no first present"
  grep -q 'wayland_touch attached seat=0 touch=0' "$o" || fail "NS: the touch listener did not report seat=0 touch=0"
  grep -q 'ms TERM sent to pid' "$t" || fail "NS: the session did not SIGTERM the engine ($(tail -1 "$t"))"
  grep -q 'quit_requested signal=15 ' "$o" || fail "NS: the engine did not quit on SIGTERM (--quit-on-term)"
  echo "   NS pass (no wl_seat global, $(grep -o 'first_present_ms=[0-9]*' "$o" | head -1), exit 0 on SIGTERM)"
}
if [ "$ONLY_NS" = 1 ]; then
  noseat
  echo "${TAG}_WAYLAND_TOUCH_NOSEAT_PASS (no wl_seat: first present, exit 0 on SIGTERM)"
  exit 0
fi

echo "== $ARCH: positive run (listener attached) =="
run pos
P="$WORK/pos/engine.out"
grep -q 'wayland_touch attached seat=1 touch=1' "$P" || fail "listener did not bind wl_touch"
alerts="$(grep -o 'alert=[a-z0-9-]*' "$P" | tr '\n' ' ' || true)"  # none = arms below say why
echo "   alerts: $alerts"
echo "   $(grep 'wayland_touch downs=' "$P")"
[ "$(grep -c 'alert=pressed-tap-b' "$P")" -eq 1 ] || fail "A: tap at (300,50) did not press tap-b exactly once"
[ "$(grep -c 'alert=pressed-tap-a' "$P")" -eq 0 ] || fail "A/D: tap-a pressed but never tapped"
[ "$(grep -c 'alert=drag-right' "$P")" -eq 1 ] || fail "C: 250 pt drag did not reach the PanResponder as drag-right"
[ "$(grep -c 'alert=pressed-tap-c' "$P")" -eq 1 ] || fail "D: tap at (500,50) did not press tap-c exactly once"
[ "$(grep -c 'alert=' "$P")" -eq 3 ] || fail "B: expected exactly 3 alerts (the empty-space tap must not press anything), got: $alerts"
grep -q 'wayland_touch downs=4 moves=3 ups=4' "$P" || fail "listener counts wrong: $(grep 'wayland_touch downs=' "$P")"
echo "   A B C D pass"

echo "== $ARCH: negative run (RNI_WAYLAND_TOUCH=0, same binary, same touches) =="
RNI_WAYLAND_TOUCH=0 run neg
N="$WORK/neg/engine.out"
grep -q 'wayland_touch disabled' "$N" || fail "N: negative arm did not disable the listener"
[ "$(grep -c 'alert=' "$N")" -eq 0 ] || fail "N: alerts fired with the listener off: GLFW is delivering touch itself?"
grep -q 'touch_downs=0 ' "$N" || fail "N: touch_downs nonzero with the listener off"
echo "   N pass (Weston injected the same 11 events; GLFW alone delivered none)"

noseat

echo "== $ARCH: X11 run (same binary, Xvfb, no Wayland socket) =="
set +e
RNI_SESSION=x11 timeout 300 bash tools/arm64-wayland-run.sh "$WORK/x11" 600 400 "" -- \
  "${BASE[@]}" --idle-run-sec "$X_SEC" > /dev/null 2>&1
xrc=$?
set -e
X="$WORK/x11/engine.out"
[ "$xrc" -eq 0 ] || { tail -20 "$X" 2>/dev/null; fail "X: engine exited $xrc under Xvfb"; }
grep -q 'glfw_platform=x11' "$X" || fail "X: GLFW did not pick X11 under Xvfb ($(grep -o 'glfw_platform=[a-z0-9]*' "$X" || echo 'no glfw_platform line'))"
grep -q 'first_present_ms=' "$X" || fail "X: no first present under Xvfb"
grep -q 'wayland_touch attached' "$X" && fail "X: the Wayland listener attached on an X11 run"
echo "   X pass ($(grep -o 'first_present_ms=[0-9]*' "$X" | head -1))"

# S: run-time selection when BOTH servers are up (host/GlfwPlatformSelect.h).
# S1 is the WSLg layout that put an Xvfb gate's window on Baker's desktop:
# DISPLAY names an X server, WAYLAND_DISPLAY is unset, and a compositor still
# answers on libwayland's default socket.
sel() {  # $1 arm, $2 expected platform, $3 expected reason; env = session knobs
  set +e
  RNI_SESSION_X11=1 timeout 300 bash tools/arm64-wayland-run.sh "$WORK/$1" 600 400 "" -- \
    "${BASE[@]}" --idle-run-sec "$S_SEC" > /dev/null 2>&1
  local rc=$?
  set -e
  local o="$WORK/$1/engine.out" got
  [ "$rc" -eq 0 ] || { tail -20 "$o" 2>/dev/null; fail "$1: engine exited $rc"; }
  got="$(grep -o 'glfw_platform=[a-z0-9]*' "$o" | head -1 || true)"
  [ "$got" = "glfw_platform=$2" ] || fail "$1: expected glfw_platform=$2, got '${got:-none}' ($(grep -o 'glfw_platform_hint=.*' "$o"))"
  grep -q "glfw_platform_hint=[a-z0-9]* reason=$3\$" "$o" || fail "$1: selection reason is not $3: $(grep -o 'glfw_platform_hint=.*' "$o")"
  echo "   $1 pass ($got, $(grep -o 'reason=.*' "$o" | head -1))"
}
echo "== $ARCH: selection with Weston AND Xvfb up =="
RNI_SESSION_DEFAULT_SOCKET=1 sel S1 x11 DISPLAY_set_session_not_wayland
sel S2 x11 DISPLAY_set_session_not_wayland
RNI_SESSION_TYPE=wayland sel S3 wayland 'XDG_SESSION_TYPE=wayland'
echo "${TAG}_WAYLAND_TOUCH_PASS (tap-b, miss, drag-right, tap-c; negative arm silent; no-seat start + SIGTERM exit; X11 under Xvfb; selection S1-S3)"
