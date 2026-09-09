#!/usr/bin/env bash
# P9 GATE: WINDOWED input — a real pointer click reaches a JS onPress handler.
#
# ⛔ WHY THIS EXISTS WHEN ci-input.sh IS ALREADY GREEN.
# ci-input.sh gates the input tier through the HEADLESS `--tap X,Y` probe,
# which lives in main() past the end of RunWindowed. It proved hit test +
# emitter + dispatch, all of which were correct. What it could not see was
# that the windowed path had NO CALLER: glfwSetMouseButtonCallback appeared
# zero times in the tree, so a user's click in `--window` mode reached
# nothing. 13 wired onPress handlers in hostapp v5 were inert while the input gate
# passed. An absent registration is indistinguishable from a broken hit test
# from outside the process, and only a gate that clicks can tell them apart.
#
# ⛔ THE TWO ASSERTIONS ARE NOT INTERCHANGEABLE — READ THIS BEFORE EDITING.
#
#   A. REAL CLICK (XTest). Warps the actual X pointer and presses the actual
#      button, so the event travels X server -> GLFW -> the registered
#      callback. This is the ONLY assertion that can die when the
#      registration is deleted. It requires a live X display.
#
#   B. SYNTHETIC CLICK (--click-after-frames). Calls the handler in-process
#      through GlfwSurface::synthesiseClick. It proves the coordinate
#      conversion, dispatch, and the JS handler — and it PASSES WITH THE
#      REGISTRATION DELETED. It is the portable half, not the proof.
#
# Deleting A and keeping B would leave a gate that is green on the exact bug
# this gate was written for. tools/mutation-verify-window-input.sh asserts A
# dies on M1 specifically for that reason.
#
# ⚠️ Needs DISPLAY and python3 + python-xlib for the XTest half. Without them
# the gate SKIPS assertion A loudly rather than passing quietly — a skip that
# reads as a pass is how this class of bug survives.
set -euo pipefail
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p9-input"

fail() { echo "WINDOW_INPUT_GATE_FAIL: $*" >&2; exit 1; }

unset SDL_VIDEODRIVER || true
export DISPLAY="${DISPLAY:-:0}"

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"
bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH" > /dev/null || fail "engine build failed"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() {
  pgrep -x rn-impeller > /dev/null 2>&1 && pkill -x rn-impeller || true
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "${RNI_ENGINE_PKG}" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/WindowInputApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="windowinputapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9Input"; a.displayName="Input Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the P9 input fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"

# The fixture's three boxes span y=0..300 at full width, in POINTS. The window
# is created at 400x300 so 1 point == 1 pixel == 1 window coordinate here, and
# a mismatch between what is clicked and what is hit is therefore attributable
# to the dispatch path rather than to arithmetic in this script.
WIN_W=400
WIN_H=300

echo "== 3. assert A: a REAL pointer click reaches a JS onPress handler =="
XCLICK="$CI_TOOLS/xclick.py"
# ⛔ python-xlib is rarely installed system-wide, and PEP 668 blocks a plain
# `pip install` into the system interpreter on modern distros. Accept an
# explicit interpreter via RNI_PYTHON (a venv's python), else try the usual
# ones. Whichever is found must be able to `import Xlib.ext.xtest` AND open
# the display — importing is not enough, a headless CI box imports fine.
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
[ -f "$XCLICK" ] || XTEST_OK=0

if [ "$XTEST_OK" = "0" ]; then
  # ⛔ LOUD, AND IT DOES NOT COUNT AS A PASS.
  # This is the only assertion that can catch an unregistered callback. A
  # silent skip here would make the gate green on the bug it exists for.
  echo "WINDOW_INPUT_GATE_SKIP_A: no DISPLAY / python-xlib — the REAL-click"
  echo "  assertion did not run. Assertion B below CANNOT detect a missing"
  echo "  glfwSetMouseButtonCallback. Do not read this run as full coverage."
else
  REAL_LOG="$WORK/real-click.log"
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name P9Input \
              --width "$WIN_W" --height "$WIN_H" --frames 5000 > "$REAL_LOG" 2>&1 &
  APP_PID=$!
  sleep 4
  "$XPY" "$XCLICK" "React Native (Impeller)" 200 150 > "$WORK/xclick.log" 2>&1
  XRC=$?
  wait "$APP_PID"
  APPRC=$?
  set -e
  [ "$XRC" -eq 0 ] || { sed 's/^/   /' "$WORK/xclick.log" >&2; fail "XTest click driver failed (rc=$XRC)"; }
  [ "$APPRC" -eq 0 ] || { tail -20 "$REAL_LOG" | sed 's/^/   /' >&2; fail "windowed app exited $APPRC"; }
  sed 's/^/   /' "$WORK/xclick.log"

  # touch_downs is asserted BEFORE touch_hits on purpose. touch_downs=0 means
  # the callback never fired (the pre-fix state); touch_downs>0 with hits=0
  # means clicks arrived and the hit test found nothing. Collapsing those two
  # into one assertion would report an unregistered callback as "nothing under
  # the cursor" and send the next reader into the hit test, which is fine.
  DOWNS="$(sed -n 's/^rn-impeller: touch_downs=\([0-9]*\) .*/\1/p' "$REAL_LOG" | tail -1)"
  HITS="$(sed -n 's/^rn-impeller: touch_downs=[0-9]* touch_hits=\([0-9]*\)$/\1/p' "$REAL_LOG" | tail -1)"
  ALERTS="$(sed -n 's/^rn-impeller: alerts_after_clicks=\([0-9]*\)$/\1/p' "$REAL_LOG" | tail -1)"
  [ -n "$DOWNS" ] || { tail -20 "$REAL_LOG" | sed 's/^/   /' >&2; fail "no touch_downs line — the app did not reach its exit counters"; }
  [ "$DOWNS" -ge 1 ] \
    || fail "REAL pointer click produced touch_downs=0 — the GLFW mouse-button callback never fired. This is the unregistered-callback bug: nothing in the windowed path calls dispatchTouch."
  [ "$HITS" -ge 1 ] \
    || fail "the click was delivered (touch_downs=$DOWNS) but hit nothing (touch_hits=0) — callback is registered, the hit test or the coordinate conversion is wrong"
  [ -n "$ALERTS" ] && [ "$ALERTS" -ge 1 ] \
    || fail "click hit a target but alerts_after_clicks=$ALERTS — the press resolved a tag and no onPress handler RAN in JS"
  echo "   OK: real X pointer click -> touch_downs=$DOWNS touch_hits=$HITS alerts=$ALERTS"
fi

echo "== 4. assert B: geometry — clicks at three points hit three distinct tags =="
# Uses the in-process hook so this half runs on any host. It cannot prove the
# callback is registered (see the header); it proves the conversion and the
# hit resolution, which is what a coordinate regression would break.
run_click() {
  local spec="$1" log="$2"
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name P9Input \
              --width "$WIN_W" --height "$WIN_H" --frames 40 \
              --click-after-frames "$spec" > "$log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$log" | sed 's/^/   /' >&2; fail "--click-after-frames $spec exited $rc"; }
}

HIT_top=""; HIT_mid=""; HIT_bot=""
for spec in "5:200,50:top" "5:200,150:mid" "5:200,250:bot"; do
  point="${spec%:*}"; name="${spec##*:}"
  LOG="$WORK/click-$name.log"
  run_click "$point" "$LOG"
  TAG="$(sed -n 's/^rn-impeller: touch_down hit=\([0-9]*\) .*/\1/p' "$LOG" | head -1)"
  [ -n "$TAG" ] || { tail -20 "$LOG" | sed 's/^/   /' >&2; fail "no touch_down line for $name — the click hook did not reach the handler"; }
  [ "$TAG" != "0" ] || { tail -20 "$LOG" | sed 's/^/   /' >&2; fail "click at $point ($name) hit NOTHING"; }
  eval "HIT_$name=\$TAG"
  echo "   $name via $point -> tag $TAG"
done

# Three disjoint boxes must answer with three DIFFERENT tags. Catches a
# conversion that collapses every coordinate to the same place (a scale of 0,
# a NaN clamped to the origin) and a hit test that ignores geometry.
UNIQ="$(printf '%s\n' "$HIT_top" "$HIT_mid" "$HIT_bot" | sort -u | wc -l | tr -d ' ')"
[ "$UNIQ" -eq 3 ] \
  || fail "three disjoint boxes returned $UNIQ distinct tags ($HIT_top/$HIT_mid/$HIT_bot) — coordinates are not selecting the target"
echo "   OK: three disjoint boxes -> three distinct tags"

echo "== 5. assert C: a miss is a miss =="
# Without this, a conversion that returns a constant, or a hit test that
# returns the root for everything, passes assertions A and B.
MISS_LOG="$WORK/click-miss.log"
run_click "5:2000,2000" "$MISS_LOG"
MISS="$(sed -n 's/^rn-impeller: touch_down hit=\([0-9]*\) .*/\1/p' "$MISS_LOG" | head -1)"
[ "$MISS" = "0" ] \
  || fail "click far outside the surface returned tag $MISS — the hit test answers for ANY point"
echo "   OK: off-surface click -> hit=0"

echo "== 6. assert D: the coordinate conversion is right at non-1x scales =="
# ⛔ THE FACTOR-OF-TWO CANNOT BE SEEN ON THIS 1x HOST BY CLICKING.
# At scale 1 the three unit systems (screen coords, pixels, layout points)
# are numerically identical, so every click assertion above passes whether
# the conversion is correct or is the identity function. --scale 2 separates
# them: the surface is 400x300 PIXELS laid out as 200x150 POINTS, so a click
# at screen coordinate 200,100 must arrive as layout point 100,50 — inside
# the top box — and NOT as 200,100, which would land in the mid box, and not
# as 400,200, which is off the surface entirely.
SCALE_LOG="$WORK/click-scale2.log"
set +e
"$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name P9Input \
            --width "$WIN_W" --height "$WIN_H" --scale 2 --frames 40 \
            --click-after-frames "5:200,100" > "$SCALE_LOG" 2>&1
SRC=$?
set -e
[ "$SRC" -eq 0 ] || { tail -20 "$SCALE_LOG" | sed 's/^/   /' >&2; fail "--scale 2 click run exited $SRC"; }
AT="$(sed -n 's/^rn-impeller: touch_down hit=[0-9]* at=\(.*\)$/\1/p' "$SCALE_LOG" | head -1)"
[ "$AT" = "100.0,50.0" ] \
  || fail "at --scale 2 a screen click at 200,100 arrived as '$AT', expected '100.0,50.0' — the cursor is not being converted into layout points (this is the factor-of-two that hits the wrong element on a Retina Mac)"
echo "   OK: --scale 2 converts screen 200,100 -> layout 100.0,50.0"

# The pure conversion's own table, over the number pairs a 2x Mac produces.
SELFTEST="$("$RESOLVED" --test-pointscale 2>&1)" || fail "pointscale selftest exited nonzero"
echo "$SELFTEST" | grep -q "^CURSORPOINTS_SELFTEST_OK" \
  || { echo "$SELFTEST" | sed 's/^/   /' >&2; fail "CursorPointsFromScreen selftest did not pass"; }
echo "   OK: CURSORPOINTS_SELFTEST_OK"

if [ "$XTEST_OK" = "0" ]; then
  echo "WINDOW_INPUT_GATE_PARTIAL (assertions B/C/D only — the REAL-click assertion was skipped)"
  exit 0
fi
echo "WINDOW_INPUT_GATE_PASS (real click + geometry + miss + scale conversion)"
