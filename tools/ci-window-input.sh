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
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
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
  rni_kill_own
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
# ⛔ THE EXPECTED NUMBER IS NOT A CONSTANT — IT DEPENDS ON THE HOST'S DISPLAY.
# The conversion is `cursor * (fb/win) / pointScale`. On this 1x host fb/win
# is 1, so `--scale 2` on a click at 200 must yield 100. On a Retina Mac
# fb/win is 2, and the SAME correct code must yield 200. An earlier version of
# this assertion hardcoded 100.0,50.0 and therefore FAILED on darwin against a
# correct engine — it was asserting the CI host's display, not the arithmetic.
# (Caught by the macOS tester running this gate on darwin-arm64 at d682627.)
#
# The fix is to assert the RELATION the conversion defines, which is identical
# on every display, instead of one absolute number that encodes fb/win:
#
#   D1  no --scale: pointScale IS fb/win, the factors cancel, and the click
#       must come back UNCHANGED on any host. A host-independent anchor.
#   D2  --scale 2 vs --scale 4: only the divisor differs, so the two answers
#       must be in an exact 2:1 ratio whatever fb/win is. This is the
#       load-bearing one — the identity conversion gives 1:1, multiplying
#       instead of dividing gives 1:2, and reading a DERIVED scale in place of
#       the --scale override also gives 1:1, so all three die here on ANY
#       host including a 1x one.
#   D3  absolute value at --scale 2, against fb/win measured INDEPENDENTLY
#       from the framebuffer size the engine reports versus the window size we
#       requested — not recomputed with the function under test.
click_at() {
  local scaleargs="$1" log="$2"
  set +e
  # shellcheck disable=SC2086
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name P9Input \
              --width "$WIN_W" --height "$WIN_H" $scaleargs --frames 40 \
              --click-after-frames "5:200,100" > "$log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$log" | sed 's/^/   /' >&2; fail "click run [$scaleargs] exited $rc"; }
  sed -n 's/^rn-impeller: touch_down hit=[0-9]* at=\(.*\)$/\1/p' "$log" | head -1
}

AT_DERIVED="$(click_at "" "$WORK/click-derived.log")"
[ "$AT_DERIVED" = "200.0,100.0" ] \
  || fail "with no --scale a screen click at 200,100 arrived as '$AT_DERIVED', expected '200.0,100.0' — with the scale derived from the framebuffer the device ratio and the point scale must cancel exactly, on a 1x display and on a Retina one alike"
echo "   OK: derived scale is identity — screen 200,100 -> layout $AT_DERIVED"

AT2="$(click_at "--scale 2" "$WORK/click-scale2.log")"
AT4="$(click_at "--scale 4" "$WORK/click-scale4.log")"
[ -n "$AT2" ] && [ -n "$AT4" ] \
  || fail "no touch_down line from the --scale runs (scale2='$AT2' scale4='$AT4')"
X2="${AT2%%,*}"; Y2="${AT2##*,}"
X4="${AT4%%,*}"; Y4="${AT4##*,}"
RATIO_OK="$(awk -v a="$X2" -v b="$X4" -v c="$Y2" -v d="$Y4" \
  'BEGIN { if (b <= 0 || d <= 0) { print "zero"; exit }
           rx = a / b; ry = c / d;
           print ((rx > 1.999 && rx < 2.001 && ry > 1.999 && ry < 2.001) ? "ok" : "bad") }')"
[ "$RATIO_OK" = "ok" ] \
  || fail "doubling --scale from 2 to 4 must halve the layout coordinate, but the click at 200,100 arrived as '$AT2' at --scale 2 and '$AT4' at --scale 4 (ratio must be exactly 2:1). A 1:1 ratio means the cursor is not being divided by the EFFECTIVE scale at all — either the conversion is the identity, or it is reading the scale derived from the framebuffer instead of the explicit --scale override. A 1:2 ratio means it multiplies where it must divide. This is the factor-of-two that hits the wrong element on a Retina Mac."
echo "   OK: --scale 2 -> $AT2 and --scale 4 -> $AT4 are an exact 2:1 ratio"

# fb/win, measured from what the engine REPORTS, not recomputed by us.
PXW="$(sed -n 's/^rn-impeller: window px=\([0-9]*\)x[0-9]* .*/\1/p' "$WORK/click-scale2.log" | head -1)"
[ -n "$PXW" ] || fail "no 'window px=' line — cannot measure this host's device ratio"
EXPECT_X="$(awk -v px="$PXW" -v win="$WIN_W" 'BEGIN { printf "%.1f", 200.0 * (px / win) / 2.0 }')"
ABS_OK="$(awk -v got="$X2" -v want="$EXPECT_X" 'BEGIN { print ((got - want < 0.05 && want - got < 0.05) ? "ok" : "bad") }')"
[ "$ABS_OK" = "ok" ] \
  || fail "at --scale 2 on a host whose framebuffer is ${PXW}px for a ${WIN_W}-point window (device ratio $(awk -v p="$PXW" -v w="$WIN_W" 'BEGIN{printf "%.2f", p/w}')), a screen click at 200 must arrive as layout $EXPECT_X, not $X2"
echo "   OK: absolute check — fb ${PXW}px / win ${WIN_W}pt, --scale 2 -> x=$X2 (expected $EXPECT_X)"

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
