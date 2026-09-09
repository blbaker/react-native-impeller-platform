#!/usr/bin/env bash
# D4: does JS actually HEAR about a resize?
#
# ⛔ WHY THIS GATE EXISTS, AND WHY THE OTHER SIXTEEN DO NOT COVER IT.
# Every existing probe asserts NATIVE-side state: scene_nodes, frame= boxes,
# painted_during, refresh_paints, tap_hit, screenshot hashes. The Mac measured
# it directly (tools/boundary-audit.py): boundary-crossing 0/16 -- all sixteen
# would PASS on a build where native geometry is perfect and JS is never told.
# The rail bug lived exactly there and had nowhere in the suite to be caught.
#
# TWO INDEPENDENT ASSERTIONS, because either alone can pass for a wrong reason:
#
#   1. THE COLUMN COUNT (the real one). Bars are produced by a JS .map() over a
#      count derived from the width JS believes it has. No native re-layout can
#      add a child React did not create, so a change here is satisfiable ONLY by
#      native -> didUpdateDimensions -> useWindowDimensions -> re-render.
#      A width assertion could not discriminate: Fabric re-constrains the root
#      whether or not a line of JS ran.
#
#   2. THE DEVEVENT LINE, which says WHY when (1) fails -- delivered, dropped
#      with a named reason, or never attempted. Without it a red gate has three
#      indistinguishable causes.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "D4_FAIL: $*" >&2; exit 1; }

# ⛔ DO NOT PROBE FOR A DISPLAY WITH xdpyinfo. It is an OPTIONAL package, and on
# a box with a perfectly good X server but no x11-utils this gate reported
# "no usable X display" and exited SKIP -- a false skip, which is worse than a
# failure because it is silent and looks deliberate. Measured on this WSL box
# 2026-09-09: DISPLAY was live via WSLg's /tmp/.X11-unix/X0 the whole time.
export DISPLAY="${DISPLAY:-:0}"
_dpy="${DISPLAY#*:}"; _dpy="${_dpy%%.*}"
[ -e "/tmp/.X11-unix/X${_dpy}" ] || {
  echo "D4 SKIP: no X socket at /tmp/.X11-unix/X${_dpy} (DISPLAY=$DISPLAY)"
  echo "         run under: xvfb-run -a --server-args='-screen 0 1280x1024x24' $0"
  exit 2; }

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() {
  pgrep -x rn-impeller > /dev/null 2>&1 && pkill -x rn-impeller || true
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/D4App"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="d4app";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="D4Dimensions"; a.displayName="D4Dimensions";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"

cp "$ROOT/fixtures/d4-dimensions/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="${RNI_BIN:-$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)}" \
  || fail "engine resolver failed"

echo "== 2. bundle =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/d4.bundle \
    >/dev/null 2>&1 || fail "bundle failed"
BUNDLE="$APP/impeller/build/d4.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

echo "== 3. run windowed, resize 400x300 -> 700x500 at frame 10 =="
LOG="$WORK/d4.log"
timeout 150 "$ENGINE" --window --probe-banner off \
  --bundle "$BUNDLE" --app-name D4Dimensions \
  --width 400 --height 300 --frames 60 \
  --resize-after-frames "10:700x500" \
  > "$LOG" 2>&1 || true

echo "--- resize / DEVEVENT / node counts ---"
grep -E "rn-impeller: resize |DEVEVENT|scene_nodes" "$LOG" | head -12

RESIZED=$(grep -c "rn-impeller: resize px=" "$LOG" || true)
DELIVERED=$(grep -c "DEVEVENT: didUpdateDimensions delivered" "$LOG" || true)
DROPPED=$(grep -c "DEVEVENT: didUpdateDimensions DROPPED" "$LOG" || true)

echo
echo "resize_events=$RESIZED  devevent_delivered=$DELIVERED  devevent_dropped=$DROPPED"

# ⛔ AN UNGRADED RUN IS NOT A PASS. If the resize body never ran this gate
# learned nothing, and reporting green is how a probe that tests nothing looks
# healthy for weeks.
[ "$RESIZED" -ge 1 ] || fail "the resize body never ran -- UNGRADED, not green"

if [ "$DELIVERED" -lt 1 ]; then
  [ "$DROPPED" -ge 1 ] && fail "emit attempted and DROPPED ($DROPPED) -- JS never heard; reason is on the DEVEVENT line above"
  fail "native resized but NOTHING crossed to JS -- the exact defect 16/16 native-side probes cannot see"
fi

# THE ASSERTION THAT NEEDS A ROUND TRIP. 400px -> 2 columns, 700px -> 3.
#
# ⛔ READ scene_nodes_after_resize, NOT scene_nodes. The latter is printed only
# after startSurface and in the headless summary -- NEITHER observes a windowed
# resize. Grepping it reads the same PRE-resize number twice and reports
# "JS did not re-render" against a build that re-rendered perfectly. Measured
# 2026-09-09: D4 said 5 -> 5 with the emit confirmed delivered. False red,
# instrument not subject. The engine prints the post-resize count on its own
# line, sampled after a JS-idle wait.
BEFORE=$(grep -o "rn-impeller: scene_nodes=[0-9]*" "$LOG" | head -1 | grep -o "[0-9]*$")
AFTER=$(grep -o "scene_nodes_after_resize=[0-9]*" "$LOG" | tail -1 | cut -d= -f2)
echo "scene_nodes before=${BEFORE:-?} after_resize=${AFTER:-?}"
[ -n "${AFTER:-}" ] || fail "no scene_nodes_after_resize line -- engine too old to grade this, UNGRADED not green"
[ -n "${BEFORE:-}" ] || fail "no baseline scene_nodes line -- UNGRADED"
if [ "$AFTER" -le "$BEFORE" ]; then
  fail "node count did not grow ($BEFORE -> $AFTER): the emit was delivered but JS did not re-render more columns"
fi

echo "D4 PASS: resize crossed the JS boundary ($DELIVERED delivered emit(s), nodes ${BEFORE}->${AFTER})"
