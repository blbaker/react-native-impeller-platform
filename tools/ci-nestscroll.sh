#!/usr/bin/env bash
# ENG-02c GATE: NESTED <ScrollView> — the wheel AXIS picks the view, at one point.
#
# ⛔ WHY THIS GATE IS DISTINCT FROM ci-scroll.sh AND ci-hscroll.sh.
# Both of those have exactly ONE scrollable view on screen, so "the wheel moved
# the scroll view" and "the wheel moved the RIGHT scroll view" are the same
# sentence. Nesting splits them: a horizontal row containing a vertical list
# resolves the INNER list as the nearest ScrollView ancestor of the hit, so the
# ENG-02/02b path handed a horizontal wheel to the inner list — whose X does not
# overflow — and dropped it. The outer row never moved and sideways scroll read
# as dead. This gate is the negative space those two cannot see: at the SAME
# point (150,100),
#
#   A. dx MOVES THE OUTER ROW. Green (the right panel) slides into the viewport.
#      Dies if the walk stops at the first ScrollView (the inner list) instead
#      of continuing to the nearest ancestor that overflows the wheel axis.
#
#   B. dx LEAVES THE INNER LIST ALONE. A point still over the inner list shows
#      the same inner row it did at rest. Dies if dx leaked into the inner
#      list's Y (it cannot — inner maxY path — but a naive "move both" would).
#
#   C. dy MOVES THE INNER LIST. The visible inner row changes. Dies if the wheel
#      axis were taken from the resolved view instead of from the delta.
#
#   D. dy LEAVES THE OUTER ROW ALONE. No green appears; the point that shows
#      green after dx still shows an inner row. Dies if a dy walked up to the
#      outer row (wrong axis) or the outer moved diagonally.
#
# A+C prove each gesture moves the correct view; B+D prove it moves ONLY that
# view. All four are pixel assertions on solid, distinct colours — a stronger
# claim than "the image changed".
#
# ⚠️ Shares the synthetic --scroll-after-frames path with ci-hscroll.sh; the
# REAL-wheel callback registration is proven by ci-scroll.sh assertion A. This
# gate proves the RESOLUTION, driven through the same dx/dy synthetic wheel.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p9-nestscroll"

fail() { echo "NESTSCROLL_GATE_FAIL: $*" >&2; exit 1; }

unset SDL_VIDEODRIVER || true
export DISPLAY="${DISPLAY:-:0}"

# Outer: two 300pt panels in a 300pt viewport -> contentWidth 600, X range 300.
# Inner: four 100pt rows in a 200pt viewport -> contentHeight 400, Y range 200.
# One wheel notch is 40pt (the host's kPointsPerNotch). Two notches = 80pt: a
# partial outer scroll that leaves the inner list still visible on the left, so
# the SAME frame proves both "outer moved" and "inner stayed".
WIN_W=300
WIN_H=200
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
APP="$WORK/NestScrollApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="nestscrollapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9NestScroll"; a.displayName="NestScroll Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the ENG-02c nested-scroll fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/nestscroll.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/nestscroll.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"

# Reads the colour of one pixel at (x, y) out of a PPM. Colours are solid, so
# this identifies WHICH panel/row is at that point -- stronger than "changed".
px() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, x, y = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
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
w, h, pix = int(parts[1]), int(parts[2]), d[i+1:]
o = (y * w + x) * 3
print("%d,%d,%d" % (pix[o], pix[o+1], pix[o+2]))
PY
}

RED="255,0,0"      # inner row 0
BLUE="0,0,255"     # inner row 1
GREEN="0,255,0"    # outer right panel

SHOT_MS=60
SCROLL_FRAME=10

run_scroll() {
  local spec="$1" shot="$2" log="$3"
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name P9NestScroll \
              --width "$WIN_W" --height "$WIN_H" --frames 400 \
              --screenshot-first "$WORK/before.ppm" \
              --scroll-after-frames "$spec" \
              --screenshot "$shot" --screenshot-after "$SHOT_MS" > "$log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$log" | sed 's/^/   /' >&2; fail "--scroll-after-frames $spec exited $rc"; }
  [ -s "$shot" ] || { tail -20 "$log" | sed 's/^/   /' >&2; fail "no post-scroll screenshot for $spec"; }
}

# Sample points, all at row y=50 (inner row 0 at rest):
#   INNER_X=100 stays inside the inner list after a 2-notch (80pt) outer scroll
#             (the inner list occupies viewport x 0..220 then).
#   OUTER_X=250 shows the green right panel only when the outer row has moved.
INNER_X=100
OUTER_X=250
SAMPLE_Y=50

echo "== 3. rest frame: inner list on the left, no green anywhere =="
# Take one throwaway run to produce before.ppm. The host rejects a 0,0 spec, so
# use a wheel UP (dy +1) which clamps to a no-op at rest (inner list already at
# offset 0) -- before.ppm is captured by --screenshot-first before any scroll.
run_scroll "${SCROLL_FRAME}:150,100,0,1" "$WORK/rest.ppm" "$WORK/rest.log"
REST_INNER="$(px "$WORK/before.ppm" "$INNER_X" "$SAMPLE_Y")"
REST_OUTER="$(px "$WORK/before.ppm" "$OUTER_X" "$SAMPLE_Y")"
[ "$REST_INNER" = "$RED" ] \
  || fail "at rest the inner list should show row 0 (red $RED) at ($INNER_X,$SAMPLE_Y); got $REST_INNER — the fixture or viewport is not what this gate assumes."
[ "$REST_OUTER" = "$RED" ] \
  || fail "at rest ($OUTER_X,$SAMPLE_Y) should still be the inner list (red $RED) with the outer row at offset 0; got $REST_OUTER. If this is green the outer row is pre-scrolled."
echo "   OK: rest shows inner row 0 (red) across the viewport, no green"

echo "== 4. assert A+B: a HORIZONTAL wheel moves the OUTER row, not the inner list =="
# dx two notches RIGHT (GLFW convention: RIGHT is negative, same flip as DOWN).
DX_LOG="$WORK/dx.log"; DX_SHOT="$WORK/dx.ppm"
run_scroll "${SCROLL_FRAME}:150,100,-2,0" "$DX_SHOT" "$DX_LOG"
DX_OUTER="$(px "$DX_SHOT" "$OUTER_X" "$SAMPLE_Y")"
DX_INNER="$(px "$DX_SHOT" "$INNER_X" "$SAMPLE_Y")"
[ "$DX_OUTER" = "$GREEN" ] \
  || fail "A: after an 80pt horizontal wheel ($OUTER_X,$SAMPLE_Y) must show the green right panel ($GREEN); got $DX_OUTER. The walk stopped at the inner list (which does not overflow X) instead of continuing to the outer row — sideways scroll is dead."
[ "$DX_INNER" = "$RED" ] \
  || fail "B: the horizontal wheel changed the inner list at ($INNER_X,$SAMPLE_Y) from red $RED to $DX_INNER. A dx must not move the inner list's Y offset."
echo "   OK: dx moved the OUTER row to green ($OUTER_X: $REST_OUTER -> $DX_OUTER); inner list stayed on row 0 ($INNER_X still $DX_INNER)"

# JS was told about the OUTER scroll (onScroll -> Alert.alert).
DX_ALERTS="$(sed -n 's/^rn-impeller: alerts_after_clicks=\([0-9]*\)$/\1/p' "$DX_LOG" | tail -1)"
[ -n "$DX_ALERTS" ] && [ "$DX_ALERTS" -ge 1 ] \
  || fail "the outer row scrolled but alerts_after_clicks=$DX_ALERTS — its onScroll never ran, so contentOffset.x is never reported to JS."
echo "   OK: JS was told about the outer scroll — alerts_after_clicks=$DX_ALERTS"

echo "== 5. assert C+D: a VERTICAL wheel moves the INNER list, not the outer row =="
# dy two notches DOWN (negative). 80pt down -> inner row 0 (red) gives way to
# row 1 (blue) at the sampled height; the outer row must stay at 0 (no green).
DY_LOG="$WORK/dy.log"; DY_SHOT="$WORK/dy.ppm"
run_scroll "${SCROLL_FRAME}:150,100,0,-2" "$DY_SHOT" "$DY_LOG"
DY_INNER="$(px "$DY_SHOT" "$INNER_X" "$SAMPLE_Y")"
DY_OUTER="$(px "$DY_SHOT" "$OUTER_X" "$SAMPLE_Y")"
[ "$DY_INNER" = "$BLUE" ] \
  || fail "C: after an 80pt vertical wheel the inner list at ($INNER_X,$SAMPLE_Y) must show row 1 (blue $BLUE); got $DY_INNER. The wheel axis was taken from the resolved view instead of the delta, so the inner list never scrolled Y."
[ "$DY_OUTER" != "$GREEN" ] \
  || fail "D: the vertical wheel revealed green at ($OUTER_X,$SAMPLE_Y) — the outer row moved on a dy. The dy walked up to the outer row (wrong axis) or drifted it diagonally."
[ "$DY_OUTER" = "$BLUE" ] \
  || fail "D: after the vertical wheel ($OUTER_X,$SAMPLE_Y) should be the inner list's row 1 (blue $BLUE) with the outer row still at 0; got $DY_OUTER."
echo "   OK: dy moved the INNER list to row 1 ($INNER_X: $REST_INNER -> $DY_INNER); outer row stayed at 0 (no green at $OUTER_X, shows $DY_OUTER)"

DY_ALERTS="$(sed -n 's/^rn-impeller: alerts_after_clicks=\([0-9]*\)$/\1/p' "$DY_LOG" | tail -1)"
[ -n "$DY_ALERTS" ] && [ "$DY_ALERTS" -ge 1 ] \
  || fail "the inner list scrolled but alerts_after_clicks=$DY_ALERTS — its onScroll never ran, so contentOffset.y is never reported to JS."
echo "   OK: JS was told about the inner scroll — alerts_after_clicks=$DY_ALERTS"

echo "NESTSCROLL_GATE_PASS (dx->outer row, dy->inner list, at one point, each leaving the other alone)"
