#!/usr/bin/env bash
# ENG-02 GATE: <ScrollView> — a real wheel scrolls the pixels AND tells JS.
#
# ⛔ WHY FOUR ASSERTIONS AND NOT ONE.
# ScrollView can fail in four ways that are individually invisible:
#
#   A. REAL WHEEL (XTest buttons 4/5). The event travels X server -> GLFW ->
#      the registered scroll callback. This is the ONLY assertion that dies
#      when glfwSetScrollCallback is deleted. Needs a live X display.
#
#   B. PIXELS MOVED. The first painted content row must differ after the
#      scroll. Catches an engine that emits perfect onScroll events over a
#      frozen tree.
#
#   C. JS WAS TOLD. alerts_after_clicks must rise, because the fixture's
#      onScroll calls Alert.alert. Catches a painter that scrolls its own
#      content and never fires the emitter -- which breaks every list with a
#      sticky header or an end-reached trigger while LOOKING perfect.
#
#   D. DIRECTION AND CLAMP. Wheel-up at rest must be a no-op, and a huge wheel
#      must stop at contentHeight - containerHeight. A sign error is a fully
#      working scroll implementation that every user calls broken, and no
#      "did the offset change" assertion can see it.
#
# B alone passes with the emitter dead. C alone passes with the painter dead.
# A alone passes if the callback fires and does nothing. Do not merge them.
#
# ⚠️ Needs DISPLAY and python-xlib for assertion A. Without them the gate SKIPS
# A loudly rather than passing quietly -- a skip that reads as a pass is how an
# unregistered callback survives a green suite. See ci-window-input.sh, which
# learned this the expensive way.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
. "$CI_TOOLS/lib/wait-for.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p9-scroll"

fail() { echo "SCROLL_GATE_FAIL: $*" >&2; exit 1; }

unset SDL_VIDEODRIVER || true
export DISPLAY="${DISPLAY:-:0}"

# The fixture's six rows are 100pt tall in a 300pt viewport, so contentHeight is
# 600, the scrollable range is exactly 300, and one wheel notch is 40pt (the
# host's kPointsPerNotch). Every expected number below derives from these.
WIN_W=400
WIN_H=300
ROW_H=100
NOTCH_PT=40

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
APP="$WORK/ScrollApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="scrollapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9Scroll"; a.displayName="Scroll Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the ENG-02 scroll fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"
# RNI_BIN overrides the installed engine (tools/ci-sanitize.sh runs this gate on the ASan build).
[ -z "${RNI_BIN:-}" ] || RESOLVED="$RNI_BIN"
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/scroll.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/scroll.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"

# Reads the colour of one pixel at (200, y) out of a PPM. The fixture's rows are
# solid and distinct, so this identifies WHICH row is at that height -- a
# stronger claim than "the image changed", which a repaint of identical content
# with one different pixel would also satisfy.
row_colour() {
  python3 - "$1" "$2" <<'PY'
import sys
path, y = sys.argv[1], int(sys.argv[2])
d = open(path, 'rb').read()
parts, i = [], 0
while len(parts) < 4:
    while d[i:i+1].isspace(): i += 1
    if d[i:i+1] == b'#':
        while d[i:i+1] != b'\n': i += 1
        continue
    s = i
    while not d[i:i+1].isspace(): i += 1
    parts.append(d[s:i])
w, h, px = int(parts[1]), int(parts[2]), d[i+1:]
o = (y * w + 200) * 3
print("%d,%d,%d" % (px[o], px[o+1], px[o+2]))
PY
}

# ⛔ THE SCREENSHOT IS ANCHORED TO THE SCROLL'S FRAME, NOT TO A CLOCK (FP-06).
# This used to be --screenshot-after 60: a deadline in ms from process start,
# "comfortably after frame 10 on every host measured". Under ASan on a box two
# lanes kept busy, frame 10 came later than 60 ms, the capture landed BEFORE the
# scroll, and a correct engine failed both the offset and the clamp assertions.
# The scroll hook fires once frame SCROLL_FRAME has painted and applies the
# offset synchronously, so the first frame painted after it already shows it;
# SHOT_FRAME leaves one spare frame. No timing assumption is left in B/C/D.
SCROLL_FRAME=10
SHOT_FRAME=$((SCROLL_FRAME + 2))
RUN_FRAMES=$((SHOT_FRAME + 6))

run_scroll() {
  local spec="$1" shot="$2" log="$3"
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name P9Scroll \
              --width "$WIN_W" --height "$WIN_H" --frames "$RUN_FRAMES" \
              --screenshot-first "$WORK/before.ppm" \
              --scroll-after-frames "$spec" \
              --screenshot "$shot" --screenshot-after-frames "$SHOT_FRAME" > "$log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$log" | sed 's/^/   /' >&2; fail "--scroll-after-frames $spec exited $rc"; }
  [ -s "$shot" ] || { tail -20 "$log" | sed 's/^/   /' >&2; fail "no post-scroll screenshot for $spec"; }
}

echo "== 3. assert A: a REAL wheel event reaches a JS onScroll handler =="
XSCROLL="$CI_TOOLS/xscroll.py"
XTEST_OK=0
XPY=""
for cand in "${RNI_PYTHON:-}" python3 "$HOME/.cache/rni/xtest-venv/bin/python"; do
  [ -n "$cand" ] || continue
  command -v "$cand" > /dev/null 2>&1 || [ -x "$cand" ] || continue
  "$cand" -c '
import sys
from Xlib import display
from Xlib.ext import xtest
try:
    display.Display()
except Exception:
    sys.exit(1)
' > /dev/null 2>&1 || continue
  XPY="$cand"; XTEST_OK=1; break
done
[ -f "$XSCROLL" ] || XTEST_OK=0

if [ "$XTEST_OK" = "0" ]; then
  # ⛔ LOUD, AND IT DOES NOT COUNT AS A PASS. This is the only assertion that
  # can catch an unregistered glfwSetScrollCallback.
  echo "SCROLL_GATE_SKIP_A: no DISPLAY / python-xlib — the REAL-wheel assertion"
  echo "  did not run. Assertions B/C/D below CANNOT detect a missing"
  echo "  glfwSetScrollCallback. Do not read this run as full coverage."
else
  REAL_LOG="$WORK/real-scroll.log"
  # FP-06: no sleeps. Wheel once the engine reports its first present (the window
  # is mapped and painted), wait for the engine's own "scroll hit=" line, then ask
  # for a clean exit; --quit-on-term drains the JS thread before the counters.
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name P9Scroll \
              --width "$WIN_W" --height "$WIN_H" --quit-on-term > "$REAL_LOG" 2>&1 &
  APP_PID=$!
  rni_track "$APP_PID"
  rni_wait_line "$REAL_LOG" '^rn-impeller: first_present_ms=' 30 "$APP_PID"
  WRC=$?
  [ "$WRC" -eq 0 ] || { tail -20 "$REAL_LOG" | sed 's/^/   /' >&2; fail "the window never reported its first present (wait rc=$WRC)"; }
  "$XPY" "$XSCROLL" "React Native (Impeller)" 200 150 -2 > "$WORK/xscroll.log" 2>&1
  XRC=$?
  rni_wait_line "$REAL_LOG" '^rn-impeller: scroll hit=' 20 "$APP_PID"
  kill -TERM "$APP_PID" 2> /dev/null
  rni_wait_exit "$APP_PID" 60
  APPRC=$?
  set -e
  [ "$XRC" -eq 0 ] || { sed 's/^/   /' "$WORK/xscroll.log" >&2; fail "XTest wheel driver failed (rc=$XRC)"; }
  [ "$APPRC" -eq 0 ] || { tail -20 "$REAL_LOG" | sed 's/^/   /' >&2; fail "windowed app exited $APPRC"; }
  sed 's/^/   /' "$WORK/xscroll.log"

  # scroll_events is asserted BEFORE scroll_hits, for the reason the input gate
  # asserts touch_downs before touch_hits: events=0 means the callback never
  # fired (the unregistered state), events>0 with hits=0 means the wheel arrived
  # over nothing scrollable. Collapsing them reports the first as the second.
  EVENTS="$(sed -n 's/^rn-impeller: scroll_events=\([0-9]*\) .*/\1/p' "$REAL_LOG" | tail -1)"
  SHITS="$(sed -n 's/^rn-impeller: scroll_events=[0-9]* scroll_hits=\([0-9]*\)$/\1/p' "$REAL_LOG" | tail -1)"
  RALERTS="$(sed -n 's/^rn-impeller: alerts_after_clicks=\([0-9]*\)$/\1/p' "$REAL_LOG" | tail -1)"
  [ -n "$EVENTS" ] || { tail -20 "$REAL_LOG" | sed 's/^/   /' >&2; fail "no scroll_events line — the app did not reach its exit counters"; }
  [ "$EVENTS" -ge 1 ] \
    || fail "REAL wheel produced scroll_events=0 — the GLFW scroll callback never fired. This is the unregistered-callback bug: nothing in the windowed path calls dispatchScroll."
  [ "$SHITS" -ge 1 ] \
    || fail "the wheel was delivered (scroll_events=$EVENTS) but hit nothing (scroll_hits=0). THREE causes, in order of likelihood: (1) the ScrollView descriptor is UNREGISTERED, so the node mounts with a base ViewEventEmitter and the ScrollViewEventEmitter cast in dispatchScroll fails — note the offset still moved and the pixels still scrolled, this counter is the only thing that sees it; (2) the scrollable-ancestor lookup did not find a ScrollView above the hit node; (3) the coordinate conversion put the wheel outside the content."
  [ -n "$RALERTS" ] && [ "$RALERTS" -ge 1 ] \
    || fail "wheel hit a ScrollView but alerts_after_clicks=$RALERTS — the scroll resolved a tag and no onScroll handler RAN in JS. An UNREGISTERED ScrollView mounts with a base ViewEventEmitter and produces exactly this."
  echo "   OK: real X wheel -> scroll_events=$EVENTS scroll_hits=$SHITS alerts=$RALERTS"
fi

echo "== 4. assert B+C: the pixels move AND JS is told =="
DOWN_LOG="$WORK/scroll-down.log"
DOWN_SHOT="$WORK/down.ppm"
# Two notches DOWN. dy is in GLFW's convention, so DOWN is negative.
run_scroll "${SCROLL_FRAME}:200,150,0,-2" "$DOWN_SHOT" "$DOWN_LOG"

BEFORE_TOP="$(row_colour "$WORK/before.ppm" 5)"
AFTER_TOP="$(row_colour "$DOWN_SHOT" 5)"
[ "$BEFORE_TOP" = "255,0,0" ] \
  || fail "at rest the top row should be the first fixture row (255,0,0), got $BEFORE_TOP — the fixture or the viewport is not what this gate assumes"

# ⛔ SAMPLE AT A HEIGHT THE OFFSET ACTUALLY CROSSES A ROW BOUNDARY AT.
# The first version of this gate asserted the pixel at y=5 changed. Two notches
# is 80pt and the rows are 100pt, so viewport y=5 still shows row 0 both before
# and after -- a CORRECT 80pt scroll failed the gate. The engine was right and
# the assertion was wrong, which is the more dangerous direction only because it
# is the one that gets "fixed" by weakening the check.
#
# The honest assertion is the FULL COLUMN: for each sample height, the row that
# must be there is ((y + offset) / ROW_H). That is a different expected value
# per height, so a scroll of the wrong DISTANCE fails it even where a scroll of
# the wrong-but-nonzero distance would still change the top pixel.
ROW_COLOURS="255,0,0 0,255,0 0,0,255 255,255,0 255,0,255 0,255,255"
expect_row_at() {  # $1 = viewport y, $2 = offset in points
  local idx=$(( ($1 + $2) / ROW_H ))
  echo "$ROW_COLOURS" | cut -d' ' -f$(( idx + 1 ))
}

OFFSET=$(( 2 * NOTCH_PT ))
MOVED=0
for y in 5 150 295; do
  GOT="$(row_colour "$DOWN_SHOT" "$y")"
  WANT="$(expect_row_at "$y" "$OFFSET")"
  REST="$(row_colour "$WORK/before.ppm" "$y")"
  [ "$GOT" = "$WANT" ] \
    || fail "two notches down is a ${OFFSET}pt offset, so viewport y=$y must show row $(( (y + OFFSET) / ROW_H )) ($WANT); got $GOT. The scroll moved by the wrong distance -- an inequality check against the resting frame would have accepted this."
  [ "$GOT" = "$REST" ] || MOVED=1
done
# At least one sample must actually differ from the resting frame, or the whole
# column assertion above is satisfiable by a scroll that never happened.
[ "$MOVED" -eq 1 ] \
  || fail "every sampled row is identical to the resting frame — the content did not move. onScroll may still be firing perfectly; a scroll that reports motion it never performed is the failure this assertion exists for."
echo "   OK: pixels moved — ${OFFSET}pt offset verified at y=5/150/295 (top row $BEFORE_TOP -> $AFTER_TOP)"

DALERTS="$(sed -n 's/^rn-impeller: alerts_after_clicks=\([0-9]*\)$/\1/p' "$DOWN_LOG" | tail -1)"
[ -n "$DALERTS" ] && [ "$DALERTS" -ge 1 ] \
  || fail "the content scrolled but alerts_after_clicks=$DALERTS — nothing ran in JS. The painter is scrolling and the emitter is dead, which breaks sticky headers and end-reached triggers while looking perfect on screen."
echo "   OK: JS was told — alerts_after_clicks=$DALERTS"

echo "== 5. assert D: direction and clamp =="
# D1: wheel UP at rest. The list is already at the top, so the clamp must make
# this a no-op. If the sign were inverted this would scroll DOWN and the top row
# would change -- which assertion B would happily call a working scroll.
UP_LOG="$WORK/scroll-up.log"
UP_SHOT="$WORK/up.ppm"
run_scroll "${SCROLL_FRAME}:200,150,0,2" "$UP_SHOT" "$UP_LOG"
UP_TOP="$(row_colour "$UP_SHOT" 5)"
[ "$UP_TOP" = "$BEFORE_TOP" ] \
  || fail "scrolling UP from rest changed the top row from $BEFORE_TOP to $UP_TOP. The list was already at offset 0, so this means the wheel sign is INVERTED: the engine scrolls the wrong way, which every assertion about 'did the offset change' passes."
echo "   OK: wheel up at rest is a no-op (top row still $UP_TOP)"

# D2: an absurd wheel must stop at contentHeight - containerHeight = 300pt,
# putting the LAST row (index 3 at the top of a 300pt viewport showing rows
# 3,4,5) at the top. An unclamped offset scrolls into empty space forever while
# still emitting plausible onScroll events -- the list goes blank.
CLAMP_LOG="$WORK/scroll-clamp.log"
CLAMP_SHOT="$WORK/clamp.ppm"
run_scroll "${SCROLL_FRAME}:200,150,0,-50" "$CLAMP_SHOT" "$CLAMP_LOG"
CLAMP_TOP="$(row_colour "$CLAMP_SHOT" 5)"
CLAMP_BOT="$(row_colour "$CLAMP_SHOT" 295)"
[ "$CLAMP_TOP" = "255,255,0" ] \
  || fail "a 50-notch (2000pt) wheel should CLAMP at contentHeight-containerHeight = 300pt, putting row 3 (255,255,0) at the top; got $CLAMP_TOP. An unclamped offset scrolls the content off the screen entirely."
[ "$CLAMP_BOT" = "0,255,255" ] \
  || fail "at the clamped offset the bottom of the viewport must be the LAST row (0,255,255); got $CLAMP_BOT — the content is scrolled past its own end."
echo "   OK: clamped at 300pt — top row $CLAMP_TOP, bottom row $CLAMP_BOT"

if [ "$XTEST_OK" = "0" ]; then
  echo "SCROLL_GATE_PARTIAL (assertions B/C/D only — the REAL-wheel assertion was skipped)"
  exit 0
fi
echo "SCROLL_GATE_PASS (real wheel + pixels moved + JS told + direction/clamp)"
