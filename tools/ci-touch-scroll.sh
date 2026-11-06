#!/usr/bin/env bash
# TOUCH DRAG-TO-SCROLL GATE: a one-finger touchscreen drag scrolls a ScrollView.
#
# On the RK3588 board the only input is a touchscreen. wl_touch reaches the
# engine through GlfwSurface::synthesiseTouch; this gate drives the SAME entry
# with the --mouse-after-frames t* ops (tdown/tmove/tup/tcancel), one event
# per frame, in a real window under X. Fixture: fixtures/touch-scroll.
#
# Arms (each a separate run; every assertion reads what JS saw):
#   A  vertical drag of 400 pt, held still before lifting: onScrollBeginDrag,
#      onScroll growing to 390 (400 minus the 10 pt slop), onScrollEndDrag at
#      390, no momentum, the pressed row gets touchcancel and no onPress.
#   B  the same drag lifted while moving: momentum continues past 390 with
#      onMomentumScrollBegin/End, and stays inside the content.
#   C  pagingEnabled pager: a 400 pt drag settles on page 1 (x=600); a 150 pt
#      slow drag springs back to page 0 (x=0); a quick 120 pt flick goes to
#      page 1 on velocity.
#   D  a tap, and a tap with 4 pt of jitter, still press the row (no drag).
#   E  a MOUSE drag scrolls nothing: desktop behaviour is unchanged.
#   F  a PanResponder outside any ScrollView still gets the whole drag.
#   G  tcancel mid-drag ends the drag where the finger was (x=390, not the
#      far-away cancel point) and the pager still settles on a page.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/touch-scroll"
APP_NAME="TouchScrollFixture"

fail() { echo "TOUCH_SCROLL_GATE_FAIL: $*" >&2; exit 1; }

unset SDL_VIDEODRIVER || true
export DISPLAY="${DISPLAY:-:0}"

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"
if [ "${RNI_SKIP_BUILD:-0}" != "1" ]; then
  bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH" > /dev/null || fail "engine build failed"
fi

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
APP="$WORK/TouchScrollApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="touchscrollapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="TouchScrollFixture"; a.displayName="Touch Scroll Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the touch-scroll fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/react-native-impeller-platform/src/bin/engine-path.js)" || fail "engine resolver failed"
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/touch-scroll.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/touch-scroll.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"

WIN_W=1000
WIN_H=700

# drag OP_PREFIX X0 Y0 X1 Y1 STEPS HOLD -> "Pdown@..;Pmove@..;..;Pup@.."
# HOLD extra moves at the end point keep the finger still before it lifts.
drag() {
  local p="$1" x0="$2" y0="$3" x1="$4" y1="$5" n="$6" hold="$7" i s
  s="${p}down@${x0},${y0}"
  for ((i = 1; i <= n; i++)); do
    s+=";${p}move@$((x0 + (x1 - x0) * i / n)),$((y0 + (y1 - y0) * i / n))"
  done
  for ((i = 0; i < hold; i++)); do s+=";${p}move@${x1},${y1}"; done
  echo "${s};${p}up@${x1},${y1}"
}

assert_scene_mounted() {  # $1 = log path
  local nodes
  nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$1" | tail -1)"
  [ -n "$nodes" ] || { tail -30 "$1" | sed 's/^/   /' >&2; fail "no 'scene_nodes=' line -- the app did not reach startSurface"; }
  [ "$nodes" -gt 0 ] || fail "scene_nodes=$nodes -- the fixture mounted NOTHING"
}
dump() {
  { grep -E '^\[js\]|touch_scroll|touch_down' "$1" | grep -v 'SCROLL [xy]=' | sed 's/^/   /' >&2; } || true
  echo "   onScroll lines: $(grep -cE '^\[js\] [VH]_SCROLL' "$1" || true)" >&2
}
has()  { grep -qE "^\[js\] $2" "$1"; }
cnt()  { grep -cE "^\[js\] $2" "$1" || true; }
# Last value of "<TAG> <axis>=<n>" in the log, or empty.
last() { sed -n "s/^\[js\] $2 [xy]=\(-\{0,1\}[0-9]*\)\$/\1/p" "$1" | tail -1; }

run_win() {  # $1=log $2=frames $3=sequence
  # The fling and the page settle run on wall time, not frames, and Xvfb does
  # not pace swaps (about 3 ms a frame here), so arms that wait for a settle
  # get frames to spare.
  local log="$1" frames="$2" seq="$3"
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name "$APP_NAME" \
      --width "$WIN_W" --height "$WIN_H" --frames "$frames" \
      --mouse-after-frames "10:$seq" > "$log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -30 "$log" | sed 's/^/   /' >&2; fail "windowed run exited $rc ($log)"; }
  assert_scene_mounted "$log"
}

echo "== A. vertical drag of 400 pt, held before lifting =="
run_win "$WORK/a.log" 120 "$(drag t 150 500 150 100 20 15)"
has "$WORK/a.log" 'V_BEGIN_DRAG y=0$' \
  || { dump "$WORK/a.log"; fail "A: no onScrollBeginDrag -- a touch drag on the list did not start a scroll"; }
A_SCROLLS="$(cnt "$WORK/a.log" 'V_SCROLL ')"
[ "$A_SCROLLS" -ge 5 ] || { dump "$WORK/a.log"; fail "A: $A_SCROLLS onScroll lines during a 20-step drag (want >= 5)"; }
A_END="$(last "$WORK/a.log" 'V_END_DRAG')"
[ "$A_END" = "390" ] || { dump "$WORK/a.log"; fail "A: onScrollEndDrag at y=$A_END, want 390 (400 pt drag minus the 10 pt slop) -- the content does not follow the finger"; }
[ "$(last "$WORK/a.log" 'V_SCROLL')" = "390" ] || { dump "$WORK/a.log"; fail "A: last onScroll is not y=390"; }
[ "$(cnt "$WORK/a.log" 'V_MOMENTUM_BEGIN')" = "0" ] || { dump "$WORK/a.log"; fail "A: momentum after a finger that stopped -- release velocity is not measured over the recent window"; }
has "$WORK/a.log" 'V_TOUCH_CANCEL' || { dump "$WORK/a.log"; fail "A: JS never got touchcancel when the scroll took the gesture -- a row stays pressed"; }
[ "$(cnt "$WORK/a.log" 'ROW_PRESS')" = "0" ] || { dump "$WORK/a.log"; fail "A: a row fired onPress at the end of a scroll drag"; }
echo "   OK: begin-drag, $A_SCROLLS onScroll to y=390, end-drag y=390, touchcancel, no press, no momentum"

echo "== B. the same drag lifted while moving (fling) =="
run_win "$WORK/b.log" 800 "$(drag t 150 500 150 100 20 0)"
[ "$(last "$WORK/b.log" 'V_END_DRAG')" = "390" ] || { dump "$WORK/b.log"; fail "B: onScrollEndDrag not at y=390"; }
has "$WORK/b.log" 'V_MOMENTUM_BEGIN y=390$' || { dump "$WORK/b.log"; fail "B: no onMomentumScrollBegin at y=390 after a moving release -- no fling"; }
B_END="$(last "$WORK/b.log" 'V_MOMENTUM_END')"
[ -n "$B_END" ] || { dump "$WORK/b.log"; fail "B: the fling never ended (no onMomentumScrollEnd) within 800 frames"; }
[ "$B_END" -gt 440 ] && [ "$B_END" -le 2400 ] || { dump "$WORK/b.log"; fail "B: fling ended at y=$B_END, want 441..2400 (past the drag, inside the content)"; }
echo "   OK: end-drag y=390, momentum 390 -> $B_END"

echo "== C. pagingEnabled pager =="
run_win "$WORK/c1.log" 400 "$(drag t 850 200 450 200 20 15)"
[ "$(last "$WORK/c1.log" 'H_END_DRAG')" = "390" ] || { dump "$WORK/c1.log"; fail "C1: pager onScrollEndDrag not at x=390 -- the horizontal drag did not scroll"; }
[ "$(last "$WORK/c1.log" 'H_MOMENTUM_END')" = "600" ] || { dump "$WORK/c1.log"; fail "C1: a 400 pt drag on a 600 pt page should settle on x=600"; }
[ "$(cnt "$WORK/c1.log" 'V_BEGIN_DRAG')" = "0" ] || fail "C1: the vertical list started a drag from a touch on the pager"
run_win "$WORK/c2.log" 400 "$(drag t 850 200 700 200 10 15)"
[ "$(last "$WORK/c2.log" 'H_END_DRAG')" = "140" ] || { dump "$WORK/c2.log"; fail "C2: pager onScrollEndDrag not at x=140"; }
[ "$(last "$WORK/c2.log" 'H_MOMENTUM_END')" = "0" ] || { dump "$WORK/c2.log"; fail "C2: a slow 150 pt drag should spring back to x=0"; }
run_win "$WORK/c3.log" 400 "$(drag t 850 200 730 200 3 0)"
[ "$(last "$WORK/c3.log" 'H_MOMENTUM_END')" = "600" ] || { dump "$WORK/c3.log"; fail "C3: a quick 120 pt flick should page to x=600 on velocity"; }
echo "   OK: 400 pt -> 600, slow 150 pt -> 0, flick 120 pt -> 600"

echo "== D. taps still press =="
run_win "$WORK/d.log" 60 "tdown@150,350;tup@150,350"
has "$WORK/d.log" 'ROW_PRESS 3$' || { dump "$WORK/d.log"; fail "D: a still tap on row 3 did not press it"; }
run_win "$WORK/d2.log" 60 "tdown@150,350;tmove@150,354;tmove@153,351;tup@153,351"
has "$WORK/d2.log" 'ROW_PRESS 3$' || { dump "$WORK/d2.log"; fail "D: a tap with 4 pt of jitter did not press row 3 -- the slop is missing"; }
[ "$(cnt "$WORK/d2.log" 'V_BEGIN_DRAG')" = "0" ] || fail "D: jitter under the slop started a scroll"
echo "   OK: tap and jittery tap both press row 3"

echo "== E. a mouse drag scrolls nothing =="
run_win "$WORK/e.log" 80 "$(drag '' 150 500 150 100 20 0)"
[ "$(cnt "$WORK/e.log" 'V_BEGIN_DRAG')" = "0" ] && [ "$(cnt "$WORK/e.log" 'V_SCROLL')" = "0" ] \
  || { dump "$WORK/e.log"; fail "E: a MOUSE drag scrolled the list -- desktop behaviour changed"; }
echo "   OK: no scroll from the mouse"

echo "== F. PanResponder outside any ScrollView =="
run_win "$WORK/f.log" 80 "$(drag t 400 450 700 450 15 0)"
has "$WORK/f.log" 'PAN_GRANT' && has "$WORK/f.log" 'PAN_RELEASE dx=300 dy=0' \
  || { dump "$WORK/f.log"; fail "F: the PanResponder strip lost its drag"; }
echo "   OK: pan-grant, pan-release dx=300"

echo "== G. tcancel mid-drag =="
G_SEQ="$(drag t 850 200 450 200 20 0)"
run_win "$WORK/g.log" 400 "${G_SEQ%;tup@*};tcancel@450,200"
[ "$(last "$WORK/g.log" 'H_END_DRAG')" = "390" ] || { dump "$WORK/g.log"; fail "G: a cancel should end the drag at x=390, not at the far-away cancel point"; }
[ "$(last "$WORK/g.log" 'H_MOMENTUM_END')" = "600" ] || { dump "$WORK/g.log"; fail "G: after a cancel the pager should still settle on x=600"; }
echo "   OK: cancel ends at x=390, settles on 600"

echo "TOUCH_SCROLL_GATE_PASS (touch drag scrolls vertical + paged ScrollViews, fling, paging, taps still press, mouse unchanged, PanResponder unchanged, cancel)"
