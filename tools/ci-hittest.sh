#!/usr/bin/env bash
# parity item 9 GATE: hit testing honours pointerEvents and transforms.
#
# Before: hitTestNode used frame rects only. An overlay with
# pointerEvents="none" swallowed clicks meant for what is under it, and a
# translated/animated button was clickable at its UNtransformed spot.
#
# Arms (one synthetic click each; the Pressable onPress logs PRESS <name>):
#   a  pointerEvents="none" overlay over PA      -> PRESS A
#   b  box-none overlay over PB                  -> PRESS B
#   c  box-none overlay's own child PBC          -> PRESS BC
#   d  box-only PC_OUTER, click on its inner child -> PRESS C_OUTER, never C_INNER
#   e  translateX:200 PD clicked where it is PAINTED (250,215) -> PRESS D
#   f  PD clicked at its untransformed spot (50,215) -> no PRESS D
#   g  scale:0 PE                                -> no PRESS E
#   h  REAL XTest click through the pointerEvents="none" overlay -> PRESS A
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item9-hittest"
APP_NAME="Item9HitTest"

fail() { echo "HITTEST_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/HitTestApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="hittestapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item9HitTest"; a.displayName="Hit Test Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 9 hit-test fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/hittest.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/hittest.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"








WIN_W=400
WIN_H=300

run_click() {  # $1 = log, $2 = "x,y"
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name "$APP_NAME" \
      --width "$WIN_W" --height "$WIN_H" --frames 40 --click-after-frames "5:$2" > "$1" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -30 "$1" | sed 's/^/   /' >&2; fail "windowed run exited $rc ($1)"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$1" || fail "the fixture mounted nothing ($1)"
}
pressed() { sed -n 's/^\[js\] PRESS \(.*\)$/\1/p' "$1" | tr '\n' ' ' | sed 's/ $//'; }
dump() { grep -E '\[js\]|touch_down' "$1" | sed 's/^/   /' >&2; }

echo "== a. click through a pointerEvents=none overlay =="
run_click "$WORK/a.log" "120,35"
[ "$(pressed "$WORK/a.log")" = "A" ] \
  || { dump "$WORK/a.log"; fail "a: a click on PA under a pointerEvents=none overlay should press A; got '$(pressed "$WORK/a.log")' -- pointerEvents none is ignored"; }
echo "   OK: PRESS A"

echo "== b/c. box-none overlay =="
run_click "$WORK/b.log" "120,95"
[ "$(pressed "$WORK/b.log")" = "B" ] \
  || { dump "$WORK/b.log"; fail "b: a click on PB under a box-none overlay should press B; got '$(pressed "$WORK/b.log")' -- pointerEvents box-none is ignored"; }
run_click "$WORK/c.log" "340,95"
[ "$(pressed "$WORK/c.log")" = "BC" ] \
  || { dump "$WORK/c.log"; fail "c: a click on the box-none overlay's own child should press BC; got '$(pressed "$WORK/c.log")' -- box-none blocks its children"; }
echo "   OK: PRESS B, PRESS BC"

echo "== d. box-only =="
run_click "$WORK/d.log" "120,155"
[ "$(pressed "$WORK/d.log")" = "C_OUTER" ] \
  || { dump "$WORK/d.log"; fail "d: a click on the inner child of a box-only Pressable should press C_OUTER only; got '$(pressed "$WORK/d.log")' -- pointerEvents box-only is ignored"; }
echo "   OK: PRESS C_OUTER"

echo "== e/f. translateX:200 =="
run_click "$WORK/e.log" "250,215"
[ "$(pressed "$WORK/e.log")" = "D" ] \
  || { dump "$WORK/e.log"; fail "e: a click where translateX:200 PAINTS PD should press D; got '$(pressed "$WORK/e.log")' -- hit testing ignores transforms"; }
run_click "$WORK/f.log" "50,215"
[ -z "$(pressed "$WORK/f.log")" ] \
  || { dump "$WORK/f.log"; fail "f: a click at PD's untransformed spot must not press it; got '$(pressed "$WORK/f.log")' -- hit testing ignores transforms"; }
echo "   OK: painted spot presses D, old spot does not"

echo "== g. scale:0 is unhittable =="
run_click "$WORK/g.log" "190,270"
[ -z "$(pressed "$WORK/g.log")" ] \
  || { dump "$WORK/g.log"; fail "g: a scale:0 Pressable must not be pressable; got '$(pressed "$WORK/g.log")' -- hit testing ignores transforms"; }
echo "   OK: no press"

echo "== h. REAL XTest click through the pointerEvents=none overlay =="
XCLICK="$CI_TOOLS/xclick.py"
XPY=""
for cand in "${RNI_PYTHON:-}" python3 "$HOME/.cache/rni/xtest-venv/bin/python"; do
  [ -n "$cand" ] || continue
  command -v "$cand" > /dev/null 2>&1 || [ -x "$cand" ] || continue
  "$cand" -c 'from Xlib import display; from Xlib.ext import xtest; display.Display()' \
      > /dev/null 2>&1 || continue
  XPY="$cand"; break
done
if [ -z "$XPY" ]; then
  echo "HITTEST_GATE_SKIP_H: no DISPLAY / python-xlib -- the REAL-click arm did not run."
else
  REAL_LOG="$WORK/real.log"
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name "$APP_NAME" \
      --width "$WIN_W" --height "$WIN_H" --idle-skip --idle-run-sec 8 > "$REAL_LOG" 2>&1 &
  PID=$!
  sleep 4
  "$XPY" "$XCLICK" "React Native (Impeller)" 120 35 250 215 > "$WORK/xc.log" 2>&1; R1=$?
  wait "$PID"; APPRC=$?
  set -e
  [ "$R1" = "0" ] || { sed 's/^/   /' "$WORK/xc.log" >&2; fail "h: XTest driver failed ($R1)"; }
  [ "$APPRC" -eq 0 ] || { tail -30 "$REAL_LOG" | sed 's/^/   /' >&2; fail "h: windowed app exited $APPRC"; }
  [ "$(pressed "$REAL_LOG")" = "A D" ] \
    || { dump "$REAL_LOG"; fail "h: REAL clicks through the none overlay and on PD's painted spot should press A then D; got '$(pressed "$REAL_LOG")' -- pointerEvents none is ignored, or hit testing ignores transforms"; }
  echo "   OK: REAL PRESS A, PRESS D"
fi

echo "HITTEST_GATE_PASS (pointerEvents none/box-none/box-only, transformed hit testing, scale 0)"
