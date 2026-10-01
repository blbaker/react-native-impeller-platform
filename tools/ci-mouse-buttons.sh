#!/usr/bin/env bash
# desktop-input-gap item 6 GATE: every mouse button reaches JS.
#
# Right/middle/back/forward presses reach JS as W3C pointer events
# (onPointerDown/onPointerUp with button 2/1/3/4, `buttons` held-mask,
# `detail` click count, shift/ctrl/alt/meta) plus onAuxClick on release.
# They start NO touch (no Pressable onPress) and do not move TextInput focus
# or the caret. The left button keeps its touch behaviour AND now also gets
# pointer events + onClick with detail = click count.
#
# Arms:
#   a  right click on the Pressable -> POINTERDOWN button=2 and AUXCLICK
#      button=2, no PRESSED
#   b  middle click -> button=1 + AUXCLICK button=1
#   c  back / forward -> button=3 / button=4
#   d  left click on the Pressable -> PRESSED + CLICK button=0 detail=1;
#      a left double click -> second POINTERDOWN detail=2
#   e  Ctrl+Shift+right click -> ctrl=1 shift=1 on POINTERDOWN
#   f  a right click on the focused TextInput leaves its caret alone (no new
#      TISEL / TIFOCUS line after the right click)
#   g  REAL XTest: X buttons 3, 2, 8 -> button=2, 1, 3 in JS; a real left
#      click still fires PRESSED
#   h  hold right, press left -> that POINTERDOWN reports buttons=3
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item6-mouse-buttons"
APP_NAME="Item6MouseButtons"

fail() { echo "MOUSE_BUTTONS_GATE_FAIL: $*" >&2; exit 1; }

unset SDL_VIDEODRIVER || true
export DISPLAY="${DISPLAY:-:0}"

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"
bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH" > /dev/null || fail "engine build failed"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() {
  rni_kill_own
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "${RNI_ENGINE_PKG}" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/MouseButtonsApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="mousebuttonsapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item6MouseButtons"; a.displayName="Mouse Buttons Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 6 mouse-buttons fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/mouse-buttons.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/mouse-buttons.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"




WIN_W=400
WIN_H=300
BTN_XY="120,40"     # inside the Pressable
TI_XY="300,98"      # inside the TextInput, past the end of its text
EMPTY_XY="300,250"  # the outer View only

assert_scene_mounted() {  # $1 = log path
  local nodes
  nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$1" | tail -1)"
  [ -n "$nodes" ] || { tail -30 "$1" | sed 's/^/   /' >&2; fail "no 'scene_nodes=' line -- the app did not reach startSurface"; }
  [ "$nodes" -gt 0 ] \
    || fail "scene_nodes=$nodes -- the fixture mounted NOTHING (mismatched --app-name is the classic cause)"
}
dump() { grep -E '\[js\]|rn-impeller: pointer|mouse_requested' "$1" | sed 's/^/   /' >&2; }
has()  { grep -qE "^\[js\] $2" "$1"; }
cnt()  { grep -cE "^\[js\] $2" "$1" || true; }

run_win() {  # $1=log $2=frames $3...=extra args
  local log="$1" frames="$2"; shift 2
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name "$APP_NAME" \
      --width "$WIN_W" --height "$WIN_H" --frames "$frames" "$@" > "$log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -30 "$log" | sed 's/^/   /' >&2; fail "windowed run exited $rc ($log)"; }
  assert_scene_mounted "$log"
}

echo "== a. right click on the Pressable =="
run_win "$WORK/a.log" 50 --mouse-after-frames "8:rdown@$BTN_XY;rup@$BTN_XY"
has "$WORK/a.log" 'POINTERDOWN button=2 buttons=2 detail=1' \
  || { dump "$WORK/a.log"; fail "a: a right press should reach JS as POINTERDOWN button=2 buttons=2 -- the right button is not forwarded to JS"; }
has "$WORK/a.log" 'AUXCLICK button=2' \
  || { dump "$WORK/a.log"; fail "a: a right click should fire onAuxClick with button=2 -- the right button is not forwarded to JS"; }
[ "$(cnt "$WORK/a.log" 'PRESSED$')" = "0" ] \
  || { dump "$WORK/a.log"; fail "a: a right click fired the Pressable's onPress -- a non-left button started an RN touch"; }
echo "   OK: button=2, auxclick, no onPress"

echo "== b. middle click =="
run_win "$WORK/b.log" 50 --mouse-after-frames "8:mdown@$EMPTY_XY;mup@$EMPTY_XY"
has "$WORK/b.log" 'POINTERDOWN button=1 buttons=4' && has "$WORK/b.log" 'AUXCLICK button=1' \
  || { dump "$WORK/b.log"; fail "b: a middle click should give POINTERDOWN button=1 buttons=4 and AUXCLICK button=1 -- the middle button is not forwarded, or is mapped to the wrong W3C button"; }
echo "   OK: button=1 buttons=4, auxclick"

echo "== c. back / forward =="
run_win "$WORK/c.log" 50 --mouse-after-frames "8:b4down@$EMPTY_XY;b4up@$EMPTY_XY;b5down@$EMPTY_XY;b5up@$EMPTY_XY"
has "$WORK/c.log" 'POINTERDOWN button=3 buttons=8' && has "$WORK/c.log" 'POINTERDOWN button=4 buttons=16' \
  || { dump "$WORK/c.log"; fail "c: back/forward should give button=3 buttons=8 and button=4 buttons=16 -- back/forward are not forwarded"; }
echo "   OK: back=3, forward=4"

echo "== d. left click and left double click =="
run_win "$WORK/d.log" 50 --mouse-after-frames "8:down@$BTN_XY;up@$BTN_XY"
has "$WORK/d.log" 'PRESSED$' \
  || { dump "$WORK/d.log"; fail "d: a left click no longer fires the Pressable's onPress -- the left button's touch path broke"; }
has "$WORK/d.log" 'CLICK button=0 buttons=0 detail=1' \
  || { dump "$WORK/d.log"; fail "d: a left click should fire onClick button=0 detail=1"; }
run_win "$WORK/d2.log" 50 --mouse-after-frames "8:down@$EMPTY_XY;up@$EMPTY_XY;down@$EMPTY_XY;up@$EMPTY_XY"
has "$WORK/d2.log" 'POINTERDOWN button=0 buttons=1 detail=2' \
  || { dump "$WORK/d2.log"; fail "d: the second press of a left double click should report detail=2 -- click count is not forwarded"; }
echo "   OK: onPress + onClick detail=1; double click detail=2"

echo "== e. Ctrl+Shift+right click =="
run_win "$WORK/e.log" 50 --mouse-after-frames "8:rdown+ctrl,shift@$EMPTY_XY;rup+ctrl,shift@$EMPTY_XY"
has "$WORK/e.log" 'POINTERDOWN button=2 buttons=2 detail=1 shift=1 ctrl=1 alt=0 meta=0' \
  || { dump "$WORK/e.log"; fail "e: Ctrl+Shift+right should report shift=1 ctrl=1 -- modifiers are dropped from pointer events"; }
echo "   OK: shift=1 ctrl=1"

echo "== f. right click on the focused TextInput keeps the caret =="
run_win "$WORK/f.log" 60 --mouse-after-frames "8:down@$TI_XY;up@$TI_XY;rdown@40,98;rup@40,98"
F_FOCUS="$(cnt "$WORK/f.log" 'TIFOCUS$')"
F_SEL_LAST="$(grep -E '^\[js\] TISEL ' "$WORK/f.log" | tail -1)"
[ "$F_FOCUS" = "1" ] && [ "$F_SEL_LAST" = "[js] TISEL start=6 end=6" ] \
  || { dump "$WORK/f.log"; fail "f: after a left click at the end and a right click at the start, focus should fire once and the caret stay {6,6}; got focus=$F_FOCUS last='$F_SEL_LAST' -- a right click moved TextInput focus or the caret"; }
echo "   OK: caret stays {6,6}, focus once"

echo "== h. hold right, press left -> buttons=3 =="
run_win "$WORK/h.log" 50 --mouse-after-frames "8:rdown@$EMPTY_XY;down@$EMPTY_XY;up@$EMPTY_XY;rup@$EMPTY_XY"
has "$WORK/h.log" 'POINTERDOWN button=0 buttons=3' \
  || { dump "$WORK/h.log"; fail "h: a left press while right is held should report buttons=3 -- the held-buttons mask is not shared across buttons"; }
echo "   OK: buttons=3"

echo "== g. REAL XTest: right, middle, back, then a left click =="
XBTN="$CI_TOOLS/xbutton.py"
XPY=""
for cand in "${RNI_PYTHON:-}" python3 "$HOME/.cache/rni/xtest-venv/bin/python"; do
  [ -n "$cand" ] || continue
  command -v "$cand" > /dev/null 2>&1 || [ -x "$cand" ] || continue
  "$cand" -c 'from Xlib import display; from Xlib.ext import xtest; display.Display()' \
      > /dev/null 2>&1 || continue
  XPY="$cand"; break
done
if [ -z "$XPY" ]; then
  echo "MOUSE_BUTTONS_GATE_SKIP_G: no DISPLAY / python-xlib -- the REAL-button arm did not run."
else
  REAL_LOG="$WORK/real.log"
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name "$APP_NAME" \
      --width "$WIN_W" --height "$WIN_H" --idle-skip --idle-run-sec 10 \
      > "$REAL_LOG" 2>&1 &
  PID=$!
  sleep 4
  "$XPY" "$XBTN" "React Native (Impeller)" "click:3@${EMPTY_XY}" "click:2@${EMPTY_XY}" \
      "click:8@${EMPTY_XY}" "click:1@${BTN_XY}" > "$WORK/xb.log" 2>&1; R1=$?
  wait "$PID"; APPRC=$?
  set -e
  [ "$R1" = "0" ] || { sed 's/^/   /' "$WORK/xb.log" >&2; fail "g: XTest driver failed ($R1)"; }
  [ "$APPRC" -eq 0 ] || { tail -30 "$REAL_LOG" | sed 's/^/   /' >&2; fail "g: windowed app exited $APPRC"; }
  assert_scene_mounted "$REAL_LOG"
  # ORDER matters: the real sequence is right, middle, back, left, so JS must
  # see button values 2 1 3 0 in that order. Checking only presence would let
  # a middle/right swap pass (both values still appear, swapped).
  G_SEQ="$(sed -n 's/^\[js\] POINTERDOWN button=\([0-9]*\) .*/\1/p' "$REAL_LOG" | tr '\n' ' ' | sed 's/ $//')"
  [ "$G_SEQ" = "2 1 3 0" ] \
    || { dump "$REAL_LOG"; fail "g: REAL X buttons 3, 2, 8 then a left click should reach JS as button 2 1 3 0; got '$G_SEQ' -- the REAL button callback drops this button or maps it to the wrong W3C button"; }
  has "$REAL_LOG" 'PRESSED$' \
    || { dump "$REAL_LOG"; fail "g: a REAL left click no longer fires onPress -- the left button's touch path broke"; }
  echo "   OK: REAL right=2, middle=1, back=3, left=0 in order; left still PRESSED"
fi

echo "MOUSE_BUTTONS_GATE_PASS (right/middle/back/forward pointer events, auxclick, click count, buttons mask, modifiers, no touch/focus for non-left)"
