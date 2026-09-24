#!/usr/bin/env bash
# ENG-02b GATE: horizontal <ScrollView> — the X delta the host used to drop now
# moves the pixels along the axis the CONTENT overflows, and a vertical wheel on
# that same list is a no-op.
#
# ⛔ WHY THIS GATE IS DISTINCT FROM ci-scroll.sh.
# The vertical gate passes with dx dropped, the axis hard-coded to Y, and the
# `horizontal` prop ignored — every one of its assertions is about the Y axis.
# This one is the negative space it cannot see:
#
#   A. HORIZONTAL PIXELS MOVE. A dx wheel over a row-laid-out ScrollView must
#      change WHICH COLUMN is at the left edge. Dies if the host still drops
#      scrollDx (the (void)scrollDx bug) or if scrollBy is Y-only.
#
#   B. THE AXIS IS DERIVED FROM OVERFLOW, NOT THE PROP. Off Android RN sends
#      horizontal={false} to native for `<ScrollView horizontal>`. If the engine
#      trusted the prop this strip would be axis-locked to Y and un-scrollable,
#      so A passing at all IS the proof the derivation works.
#
#   C. A VERTICAL WHEEL IS A NO-OP HERE. The content does not overflow in Y, so
#      a dy must not move it diagonally. Catches a host that forwards both
#      deltas but a scrollBy that adds them to both offsets unconditionally.
#
#   D. CLAMP. An absurd dx stops at contentWidth - containerWidth = 300pt.
#
# The offset.x probe printed at the end is the number the Mac peer verifies by
# symbol against the rsynced binary.
#
# ⚠️ The REAL-wheel registration arm (X buttons 6/7 for horizontal) is shared
# with ci-scroll.sh assertion A via the SAME glfwSetScrollCallback — that gate
# proves the callback is registered; this one proves the axis + X delta reach
# the scene graph. Driven through the synthetic --scroll-after-frames dx path.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p9-hscroll"

fail() { echo "HSCROLL_GATE_FAIL: $*" >&2; exit 1; }

unset SDL_VIDEODRIVER || true
export DISPLAY="${DISPLAY:-:0}"

# Six 100pt-wide columns in a 300pt viewport: contentWidth 600, scrollable range
# exactly 300, one wheel notch 40pt. Every expected number derives from these.
WIN_W=300
WIN_H=200
COL_W=100
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
APP="$WORK/HScrollApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="hscrollapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9HScroll"; a.displayName="HScroll Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the ENG-02b hscroll fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/hscroll.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/hscroll.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"

# Reads the colour of one pixel at (x, 100) out of a PPM. The fixture's columns
# are solid and distinct, so this identifies WHICH column is at that x -- a
# stronger claim than "the image changed".
col_colour() {
  python3 - "$1" "$2" <<'PY'
import sys
path, x = sys.argv[1], int(sys.argv[2])
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
o = (100 * w + x) * 3
print("%d,%d,%d" % (px[o], px[o+1], px[o+2]))
PY
}

SHOT_MS=60
SCROLL_FRAME=10

run_scroll() {
  local spec="$1" shot="$2" log="$3"
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name P9HScroll \
              --width "$WIN_W" --height "$WIN_H" --frames 400 \
              --screenshot-first "$WORK/before.ppm" \
              --scroll-after-frames "$spec" \
              --screenshot "$shot" --screenshot-after "$SHOT_MS" > "$log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$log" | sed 's/^/   /' >&2; fail "--scroll-after-frames $spec exited $rc"; }
  [ -s "$shot" ] || { tail -20 "$log" | sed 's/^/   /' >&2; fail "no post-scroll screenshot for $spec"; }
}

COL_COLOURS="255,0,0 0,255,0 0,0,255 255,255,0 255,0,255 0,255,255"
expect_col_at() {  # $1 = viewport x, $2 = offset in points
  local idx=$(( ($1 + $2) / COL_W ))
  echo "$COL_COLOURS" | cut -d' ' -f$(( idx + 1 ))
}

echo "== 3. assert A+B: a horizontal wheel moves the pixels along the derived axis =="
# Two notches RIGHT. dx is in GLFW's convention, so RIGHT is negative (same flip
# as dy DOWN). The strip carries horizontal={false} to native, so any movement
# at all is the content-overflow axis derivation working.
RIGHT_LOG="$WORK/scroll-right.log"
RIGHT_SHOT="$WORK/right.ppm"
run_scroll "${SCROLL_FRAME}:150,100,-2,0" "$RIGHT_SHOT" "$RIGHT_LOG"

BEFORE_LEFT="$(col_colour "$WORK/before.ppm" 5)"
[ "$BEFORE_LEFT" = "255,0,0" ] \
  || fail "at rest the left column should be the first fixture column (255,0,0), got $BEFORE_LEFT"

OFFSET=$(( 2 * NOTCH_PT ))
MOVED=0
for x in 5 150 295; do
  GOT="$(col_colour "$RIGHT_SHOT" "$x")"
  WANT="$(expect_col_at "$x" "$OFFSET")"
  REST="$(col_colour "$WORK/before.ppm" "$x")"
  [ "$GOT" = "$WANT" ] \
    || fail "two notches right is a ${OFFSET}pt X offset, so viewport x=$x must show column $(( (x + OFFSET) / COL_W )) ($WANT); got $GOT. Either scrollDx is still dropped at the host, or the axis was locked to the horizontal={false} prop instead of derived from content overflow."
  [ "$GOT" = "$REST" ] || MOVED=1
done
[ "$MOVED" -eq 1 ] \
  || fail "every sampled column is identical to the resting frame — the horizontal content did not move. This is the (void)scrollDx bug: the X delta was carried into a y-only handler and dropped."
echo "   OK: horizontal pixels moved — ${OFFSET}pt X offset verified at x=5/150/295 (left col $BEFORE_LEFT -> $(col_colour "$RIGHT_SHOT" 5))"

RALERTS="$(sed -n 's/^rn-impeller: alerts_after_clicks=\([0-9]*\)$/\1/p' "$RIGHT_LOG" | tail -1)"
[ -n "$RALERTS" ] && [ "$RALERTS" -ge 1 ] \
  || fail "the content scrolled horizontally but alerts_after_clicks=$RALERTS — onScroll never ran, so contentOffset.x is never reported to JS."
echo "   OK: JS was told — alerts_after_clicks=$RALERTS (contentOffset.x reported)"

echo "== 4. assert C: a VERTICAL wheel on this horizontal list is a no-op =="
# The content does not overflow in Y (columns are exactly the viewport height),
# so the derived axis is X and a dy must move nothing. A scrollBy that added dy
# to scrollY unconditionally would drift the list vertically off its content.
VERT_LOG="$WORK/scroll-vert.log"
VERT_SHOT="$WORK/vert.ppm"
run_scroll "${SCROLL_FRAME}:150,100,0,-2" "$VERT_SHOT" "$VERT_LOG"
VERT_LEFT="$(col_colour "$VERT_SHOT" 5)"
[ "$VERT_LEFT" = "$BEFORE_LEFT" ] \
  || fail "a vertical wheel changed the left column from $BEFORE_LEFT to $VERT_LEFT. The axis is X (content overflows only horizontally); a dy must be a no-op, not a diagonal drift."
echo "   OK: vertical wheel is a no-op on a horizontal list (left col still $VERT_LEFT)"

echo "== 5. assert D: horizontal clamp =="
# An absurd dx must stop at contentWidth - containerWidth = 300pt, putting the
# LAST column (index 3 at the left of a 300pt viewport showing cols 3,4,5) at the
# left edge.
CLAMP_LOG="$WORK/scroll-clamp.log"
CLAMP_SHOT="$WORK/clamp.ppm"
run_scroll "${SCROLL_FRAME}:150,100,-50,0" "$CLAMP_SHOT" "$CLAMP_LOG"
CLAMP_LEFT="$(col_colour "$CLAMP_SHOT" 5)"
CLAMP_RIGHT="$(col_colour "$CLAMP_SHOT" 295)"
[ "$CLAMP_LEFT" = "255,255,0" ] \
  || fail "a 50-notch (2000pt) wheel should CLAMP at contentWidth-containerWidth = 300pt, putting column 3 (255,255,0) at the left; got $CLAMP_LEFT."
[ "$CLAMP_RIGHT" = "0,255,255" ] \
  || fail "at the clamped X offset the right of the viewport must be the LAST column (0,255,255); got $CLAMP_RIGHT."
echo "   OK: clamped at 300pt — left col $CLAMP_LEFT, right col $CLAMP_RIGHT"

echo "HSCROLL_GATE_PASS (horizontal pixels moved + axis-from-overflow + vertical no-op + clamp)"
