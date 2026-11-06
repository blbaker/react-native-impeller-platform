#!/usr/bin/env bash
# --window-hidden GATE: the windowed path on a window nobody can see.
#   A. hidden 400x300 + a synthetic click and scroll: RN_IMPELLER_WINDOW_OK,
#      the engine's own readback (window_hidden final visible_frames=0
#      focused_frames=0 app_active_frames=0, surface 1x), the click's tag + JS
#      PRESS A, the JS SCROLL, the live timer (TICKS line + the bar in the
#      capture), the capture's size and pixels. The INDEPENDENT oracle watches
#      the window system while it runs: X11 map state (python-xlib) on linux,
#      the window server's on-screen flag (tools/darwin-onscreen-windows.c,
#      SIGKILL on the first on-screen sample) plus `lsappinfo front` on darwin.
#      found>=1 is required, so "no window seen" can never pass as "hidden".
#   B. hidden 1920x1080: the capture is exactly 1920x1080 (on a 2x Retina
#      display this is the 1x pin: the old windowed capture came out 2x).
#   C. control, today's --window, same click/scroll: the same tag, the same JS
#      lines, the same pixels as A, and the oracle SEES this window (so it can
#      see one). Linux only by default: on darwin it would open a real window
#      on the user's screen, so it runs only with RNI_ALLOW_VISIBLE_WINDOW=1.
#   D. darwin: headless --tap at the same point hits the same tag as A (a 1x
#      reference with no window at all).
# Node-free: prebuilt bundle + RNI_BIN. Prints WINDOW_HIDDEN_PASS.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OS="$(uname -s)"
BUNDLE="${RNI_TEST_BUNDLE:-$ROOT/fixtures/window-hidden/prebuilt/window-hidden.bundle}"
if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"
elif [ "$OS" = Darwin ]; then BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
fail() { echo "WINDOW_HIDDEN_FAIL: $*" >&2; exit 1; }
[ -x "$BIN" ] || fail "no engine binary at $BIN"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# A darwin window is vsynced (~400 frames in 4-15 s); xvfb is not.
if [ "$OS" = Darwin ]; then FRAMES="${RNI_FRAMES:-400}"; else FRAMES="${RNI_FRAMES:-4000}"; fi
COMMON=(--bundle "$BUNDLE" --app-name probe --probe-banner off --supersample-rnsvg 0)
INPUT=(--click-after-frames 200:70,60 --scroll-after-frames 220:200,100,0,-3)

PY=""
ORACLE=()
if [ "$OS" = Darwin ]; then
  cc -O2 -o "$WORK/onscreen" "$ROOT/tools/darwin-onscreen-windows.c" \
    -framework CoreGraphics -framework CoreFoundation || fail "could not build the darwin oracle"
else
  for cand in "${RNI_PYTHON:-}" python3 "$HOME/.cache/rni/xtest-venv/bin/python"; do
    [ -n "$cand" ] || continue
    "$cand" -c 'import Xlib' > /dev/null 2>&1 && { PY="$cand"; break; }
  done
  [ -n "$PY" ] || fail "no python with python-xlib: the X11 oracle cannot run"
fi

# run <name> <mode-flag> args...: engine in the background, oracle beside it.
# Leaves $WORK/<name>.log, .oracle, .fronts. Linux runs inside ONE xvfb-run so
# the oracle and the engine share the display.
run() {
  local name="$1" mode="$2"; shift 2
  local log="$WORK/$name.log" orc="$WORK/$name.oracle"
  local cmd=("$BIN" "${COMMON[@]}" "$mode" --frames "$FRAMES" "$@")
  if [ "$OS" = Darwin ]; then
    ( cd "$(dirname "$BIN")" && exec "${cmd[@]}" ) > "$log" 2>&1 &
    local pid=$!
    "$WORK/onscreen" "$pid" 60 --kill-on-screen > "$orc" &
    local opid=$!
    : > "$WORK/$name.fronts"
    local n=0
    while kill -0 "$pid" 2>/dev/null; do
      # The frontmost app's PID, every 100 ms. Other processes may legitimately
      # take the front during a run; what must never be front is THIS engine.
      lsappinfo info -only pid "$(lsappinfo front)" 2>/dev/null | sed -n 's/.*"pid"=\([0-9]*\).*/\1/p' >> "$WORK/$name.fronts"
      n=$((n + 1))
      # LaunchServices' own classification of the engine (Foreground = Dock icon).
      [ "$n" = 10 ] && lsappinfo info -only applicationtype "$(lsappinfo find pid="$pid")" > "$WORK/$name.apptype" 2>&1
      sleep 0.1
    done
    local rc=0; wait "$pid" || rc=$?
    wait "$opid" || true
    echo "$pid" > "$WORK/$name.pid"
    if [ "$rc" = 137 ] && ! grep -q killed_on_screen "$orc"; then
      fail "$name: SIGKILLed by something else (the macOS tester's no-test-windows guard matches any '--window' arg; exempt --window-hidden)"
    fi
    [ "$rc" = 0 ] || { tail -8 "$log" >&2; cat "$orc" >&2; fail "$name: engine exited $rc"; }
  else
    local q; q="$(printf '%q ' "${cmd[@]}")"
    xvfb-run -a -s "-screen 0 2560x1600x24" bash -c "
      cd '$(dirname "$BIN")'
      $q > '$log' 2>&1 &
      p=\$!
      '$PY' '$ROOT/tools/x11-viewable-windows.py' \$p 120 > '$orc'
      wait \$p" || { tail -8 "$log" >&2; fail "$name: engine run failed"; }
  fi
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$log" || fail "$name: the fixture mounted nothing"
  grep -q '^RN_IMPELLER_WINDOW_OK' "$log" || { tail -8 "$log" >&2; fail "$name: no RN_IMPELLER_WINDOW_OK"; }
}
oracle_hidden() {  # name: the window existed and was never on screen
  local o; o="$(cat "$WORK/$1.oracle")"; echo "   oracle: $o"
  if [ "$OS" = Darwin ]; then
    echo "$o" | grep -qE 'found=[1-9]' || fail "$1: the oracle never saw the engine's window (no evidence either way)"
    echo "$o" | grep -q 'max_onscreen=0' || fail "$1: a window was ON SCREEN ($o)"
    local fronts; fronts="$(sort -u "$WORK/$1.fronts" | tr '\n' ' ')"
    local me; me="$(cat "$WORK/$1.pid")"
    echo "   frontmost-app pids during the run: $fronts(engine pid $me, $(wc -l < "$WORK/$1.fronts" | tr -d ' ') samples)"
    [ -s "$WORK/$1.fronts" ] || fail "$1: no frontmost-app samples"
    if grep -qx "$me" "$WORK/$1.fronts"; then fail "$1: the engine became the frontmost app"; fi
    local at; at="$(tr '\n' ' ' < "$WORK/$1.apptype" 2>/dev/null || true)"
    echo "   launchservices: $at"
    if echo "$at" | grep -q '"Foreground"'; then fail "$1: LaunchServices lists the engine as a Foreground (Dock) app"; fi
  else
    echo "$o" | grep -qE 'found=[1-9]' || fail "$1: the oracle never saw the engine's window (no evidence either way)"
    echo "$o" | grep -q 'max_viewable=0' || fail "$1: a window was viewable ($o)"
  fi
}
hidden_readback() {  # name W H
  local line; line="$(grep '^rn-impeller: window_hidden final' "$WORK/$1.log" || true)"
  echo "   engine: ${line#rn-impeller: }"
  [ -n "$line" ] || fail "$1: no 'window_hidden final' line (was --window-hidden honoured?)"
  echo "$line" | grep -q "surface_px=$2x$3 points=$2x$3" || fail "$1: surface is not a 1x $2x$3 canvas"
  echo "$line" | grep -q 'visible_frames=0 focused_frames=0 app_active_frames=0' \
    || fail "$1: the engine saw its window visible/focused/active"
  grep -q "^rn-impeller: window px=$2x$3 points=$2.0x$3.0 scale=1.00" "$WORK/$1.log" \
    || fail "$1: window px/scale line is not $2x$3 at 1.00"
}
js() { { grep -E '^\[js\] (PRESS|SCROLL) ' "$1" || true; } | sed 's/^\[js\] //' | sort -u | tr '\n' ',' | sed 's/,$//'; }
tag() { sed -n 's/^rn-impeller: touch_down hit=\([0-9]*\) .*/\1/p' "$1" | head -1; }

echo "== A. hidden 400x300, click 70,60 + scroll ($OS, frames=$FRAMES) =="
run a --window-hidden --width 400 --height 300 --screenshot-after 2500 --screenshot "$WORK/a.ppm" "${INPUT[@]}"
oracle_hidden a
hidden_readback a 400 300
TAG_A="$(tag "$WORK/a.log")"; JS_A="$(js "$WORK/a.log")"
echo "   click tag=$TAG_A js=$JS_A"
[ -n "$TAG_A" ] && [ "$TAG_A" != 0 ] || fail "A: the click hit nothing"
echo "$JS_A" | grep -q 'PRESS A' || fail "A: onPress A did not fire"
echo "$JS_A" | grep -qE 'SCROLL y=[1-9]' || fail "A: onScroll did not fire with a positive offset"
grep -q '^\[js\] TICKS 20 ms=' "$WORK/a.log" || fail "A: the JS setInterval never reached 20 ticks"
echo "   $(grep '^\[js\] TICKS' "$WORK/a.log")"
[ -s "$WORK/a.ppm" ] || fail "A: no capture written"
res="$(python3 tools/window-hidden-pixels.py "$WORK/a.ppm" 400 300)" || fail "A: $res"
echo "   $res"

echo "== B. hidden 1920x1080 capture is exactly 1920x1080 =="
run b --window-hidden --width 1920 --height 1080 --screenshot-after 2500 --screenshot "$WORK/b.ppm"
oracle_hidden b
hidden_readback b 1920 1080
res="$(python3 tools/window-hidden-pixels.py "$WORK/b.ppm" 1920 1080)" || fail "B: $res"
echo "   $res"

if [ "$OS" != Darwin ] || [ "${RNI_ALLOW_VISIBLE_WINDOW:-0}" = 1 ]; then
  echo "== C. control: today's --window, same click/scroll =="
  run c --window --scale 1 --width 400 --height 300 --screenshot-after 2500 --screenshot "$WORK/c.ppm" "${INPUT[@]}"
  grep -q '^rn-impeller: window_hidden' "$WORK/c.log" && fail "C: --window printed window_hidden lines (the flag leaked)"
  o="$(cat "$WORK/c.oracle")"; echo "   oracle: $o"
  if [ "$OS" = Darwin ]; then
    echo "$o" | grep -qE 'max_onscreen=[1-9]' || fail "C: the oracle did not see the --window window on screen"
  else
    echo "$o" | grep -qE 'max_viewable=[1-9]' || fail "C: the oracle did not see the --window window viewable"
  fi
  TAG_C="$(tag "$WORK/c.log")"; JS_C="$(js "$WORK/c.log")"
  echo "   click tag=$TAG_C js=$JS_C"
  [ "$TAG_C" = "$TAG_A" ] || fail "C: --window click hit tag $TAG_C, hidden hit $TAG_A"
  [ "$JS_C" = "$JS_A" ] || fail "C: JS differs: window '$JS_C' vs hidden '$JS_A'"
  res="$(python3 tools/window-hidden-pixels.py "$WORK/a.ppm" 400 300 "$WORK/c.ppm")" || fail "C: $res"
  echo "   hidden vs window: $res"
else
  echo "== C. skipped on darwin (it would open a visible window; RNI_ALLOW_VISIBLE_WINDOW=1 runs it) =="
fi

if [ "$OS" = Darwin ]; then
  echo "== D. headless --tap 70,60 (1x, no window) hits the same tag =="
  ( cd "$(dirname "$BIN")" && "$BIN" "${COMMON[@]}" --width 400 --height 300 --headless --tap 70,60 ) \
    > "$WORK/d.log" 2>&1 || fail "D: headless run failed"
  TAG_D="$(sed -n 's/^rn-impeller: tap_hit=\([0-9]*\) .*/\1/p' "$WORK/d.log" | head -1)"
  echo "   headless tag=$TAG_D hidden tag=$TAG_A"
  [ "$TAG_D" = "$TAG_A" ] || fail "D: headless tap hit $TAG_D, hidden click hit $TAG_A"
fi

echo "WINDOW_HIDDEN_PASS"
