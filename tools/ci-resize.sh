#!/usr/bin/env bash
# RESIZE GATE: the window repaints WHILE the frame loop cannot run.
#
# ⛔ WHAT THIS GATE EXISTS TO CATCH, AND WHY THE OBVIOUS GATE DOES NOT CATCH IT.
#
# `--resize-after-frames N:WxH` already proves the resize BODY works:
# glfwSetWindowSize fires the framebuffer-size callback, the frame loop reaches
# consumeDirty() on its very next iteration, DeriveWindowPointScale re-derives,
# Dimensions updates and fabric.updateSurface re-constrains the layout. All of
# that was true BEFORE the window-refresh callback existed, and a gate built on
# --resize-after-frames alone passes identically with the fix deleted. It is a
# structurally blind gate for this defect.
#
# The defect is narrower: on macOS, holding the mouse on a window edge puts
# AppKit into a MODAL resize loop inside -[NSWindow sendEvent:]. glfwPollEvents
# does not return until the drag ends, so the dirty flag is raised many times
# and its ONLY consumer — the frame loop — is blocked the whole time. The app
# repaints once, on mouse release. glfwSetWindowSize does not enter that modal
# loop, so it cannot reproduce the condition.
#
# `--stall-after-frames N:MS` reproduces the condition's DEFINING PROPERTY on
# every platform: the loop body becomes unreachable while GLFW keeps
# dispatching event callbacks. A frame painted during that window can only have
# come from the window-refresh callback, because nothing else is running.
#
# ⚠️ HONEST LIMIT, stated so nobody upgrades this claim later: the stall is NOT
# AppKit's modal loop. It proves the repaint path works when the loop is
# blocked and events still dispatch, which is the mechanism of the macOS bug.
# It does not prove AppKit specifically invokes the refresh callback during a
# drag — that is a property of GLFW's cocoa backend (cocoa_window.m -drawRect:
# and -updateLayer: both call _glfwInputWindowDamage), verified by reading the
# vendored source, and finally by Baker's hand on a real window.
#
# THREE ASSERTIONS:
#   1. POSITIVE — with a resize requested at frame N and the loop stalled at
#      the SAME frame N, painted_during >= 1 AND the resize is applied during
#      the stall (the [fabric] resized line lands between stall_begin and
#      stall_end).
#   2. NEGATIVE CONTROL — a run with NO resize pending still completes and
#      reports the stall, so assertion 1 is measuring the resize repaint and
#      not merely "the process was alive".
#   3. NO REGRESSION — the ordinary (unstalled) resize path still works and
#      the windowed run still exits 0 with the expected frame count.
#
# ⚠️ DISPLAY=:0 required; SDL_VIDEODRIVER must be unset (see ci-window.sh).
#
# ⛔ THIS GATE IS LOAD-SENSITIVE. RUN IT ALONE, AND BELIEVE A FAILURE ONLY WHEN
#    THE BOX IS QUIET.
# Assertion 1 asks whether a repaint happened INSIDE a fixed wall-clock stall
# window. That is a timing question, so it is decided by the scheduler as well
# as by the code. Measured on WSLg (2026-09-08) while another agent's pass loop
# was running its own windowed gates on the same X display:
#   load ~1-2 : 3 of 5 runs PASS
#   load ~4-7 : 0 of 6 runs pass
# and, decisively, an A/B of the FIX ITSELF against the pre-fix narrow guard
# scored 0/6 for BOTH variants at high load -- i.e. at that point the gate had
# stopped discriminating the thing it exists to measure. A red run under
# contention is therefore not evidence of a regression; re-run it idle before
# concluding anything. Under WSLg there is no local Xvfb to isolate onto: the
# compositor is out-of-process on the Windows side and every GUI gate on this
# machine shares it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p3-conformance"

fail() { echo "RESIZE_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/ResizeApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="resizeapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P3Fixture"; a.displayName="Resize Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

cp "$FIXTURE/index.js" "$APP/index.js"
cp "$FIXTURE/fixture.json" "$APP/fixture.json"

npx --no-install react-native init-impeller 2>&1 | sed 's/^/   /' || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"

echo "== 2. bundle --platform impeller =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    2>&1 | tail -2 | sed 's/^/   /'
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

STALL_N=10
STALL_MS=1200

echo "== 3. assert 1/3: a resize requested at frame $STALL_N repaints DURING the stall =="
POS_LOG="$WORK/positive.log"
"$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name P3Fixture \
            --width 400 --height 300 --frames 60 \
            --resize-after-frames "$STALL_N:700x500" \
            --stall-after-frames "$STALL_N:$STALL_MS" \
            > "$POS_LOG" 2>&1 || fail "positive run exited non-zero"

grep -q '^RN_IMPELLER_WINDOW_OK app=P3Fixture frames=60$' "$POS_LOG" \
  || fail "positive run did not complete 60 frames"

PAINTED_DURING="$(grep -o 'stall_end refresh_paints=[0-9]* painted_during=[0-9]*' "$POS_LOG" \
                  | sed 's/.*painted_during=//')"
[ -n "$PAINTED_DURING" ] || fail "no stall_end line — the --stall-after-frames hook did not run"
[ "$PAINTED_DURING" -ge 1 ] \
  || fail "painted_during=$PAINTED_DURING: NOTHING was painted while the frame loop was blocked. This is the bug: the window-refresh callback is absent, or it marks dirty without painting, so a live macOS resize drag repaints only on mouse release."
echo "   OK: painted_during=$PAINTED_DURING frames painted from the refresh callback"

# The paint alone is not enough — it must be a paint of the NEW geometry. The
# resize log line has to land BETWEEN stall_begin and stall_end, which is only
# possible if applyResizeIfDirty ran from the callback rather than from the
# loop (the loop does not run again until after stall_end).
BETWEEN="$(awk '/stall_begin/{f=1;next} /stall_end/{f=0} f' "$POS_LOG" | grep -c 'rn-impeller: resize px=700x500' || true)"
[ "$BETWEEN" -ge 1 ] \
  || fail "a frame was painted during the stall but the RESIZE was not applied in it — the refresh handler paints without re-running the resize body, so the drag would repaint stale geometry"
echo "   OK: resize px=700x500 was applied inside the stall window"

echo "== 4. assert 2/3: negative control — stall with NO pending resize =="
NEG_LOG="$WORK/negative.log"
"$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name P3Fixture \
            --width 400 --height 300 --frames 60 \
            --stall-after-frames "$STALL_N:$STALL_MS" \
            > "$NEG_LOG" 2>&1 || fail "negative-control run exited non-zero"
grep -q 'stall_end' "$NEG_LOG" || fail "negative control never stalled"
grep -q 'rn-impeller: resize px=' "$NEG_LOG" \
  && fail "negative control reported a resize it was never asked for"
echo "   OK: the stall itself does not manufacture a resize"

echo "== 5. assert 3/3: the ordinary (unstalled) resize path still works =="
REG_LOG="$WORK/regression.log"
"$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name P3Fixture \
            --width 400 --height 300 --frames 60 \
            --resize-after-frames "10:700x500" \
            > "$REG_LOG" 2>&1 || fail "unstalled resize run exited non-zero"
grep -q 'rn-impeller: resize px=700x500 points=700.0x500.0' "$REG_LOG" \
  || fail "the ordinary loop-driven resize regressed"
grep -q '^RN_IMPELLER_WINDOW_OK app=P3Fixture frames=60$' "$REG_LOG" \
  || fail "unstalled run did not complete 60 frames"
echo "   OK: loop-driven resize unchanged"

echo "== 6. no orphan window process =="
sleep 0.3
rni_have_own && fail "orphan rn-impeller process left behind"
echo "   OK: no orphan process"

echo "RESIZE_GATE_PASS (painted_during=$PAINTED_DURING stall=${STALL_MS}ms)"
