#!/usr/bin/env bash
# ENG-09 GATE: the windowed hover/cursor tier.
#
# Proves, in ONE windowed run, the four properties of the hover feature:
#   1. ENTER    — moving the cursor over a box logs hover_enter tag=N.
#   2. QUIET    — a second move WITHIN the same box logs NOTHING (no per-move
#                 line). This is the property the peer asked for explicitly.
#   3. TRANSITION — moving to a different box logs hover_leave for the old tag
#                 AND hover_enter for the new one, and cursor= changes shape.
#   4. WINDOW-LEAVE — the cursor exiting the window logs hover_leave for the
#                 last box, so a control does not stay hovered after exit.
#
# Cursor SHAPE is asserted from ViewProps.cursor: the hand box (cursor:pointer)
# must resolve cursor=hand, the ibeam box (cursor:text) cursor=ibeam, the plain
# box cursor=arrow.
#
# ⚠️ WINDOWED, and REQUIRES AN X SERVER. WSLg provides one (DISPLAY=:0). The
# synthetic hover hook drives the SAME conversion+dispatch a real move does but
# does NOT prove glfwSetCursorPosCallback is registered — the peer's darwin
# CGEvent negative arm (registration removed, real OS motion, assert no hover
# lines) is what proves registration. This gate covers the transition logic.
set -euo pipefail
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/eng09-hover"
export DISPLAY="${DISPLAY:-:0}"

fail() { echo "HOVER_GATE_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"
bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH" > /dev/null || fail "engine build failed"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "${RNI_ENGINE_PKG}" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/HoverApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="hoverapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="ENG09Hover"; a.displayName="Hover Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the ENG-09 hover fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"

npx --no-install react-native init-impeller 2>&1 | sed 's/^/   /' || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"
# RNI_BIN overrides the installed engine (tools/ci-sanitize.sh runs this gate on the ASan build).
[ -z "${RNI_BIN:-}" ] || RESOLVED="$RNI_BIN"

echo "== 3. bundle --platform impeller =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    2>&1 | tail -3 | sed 's/^/   /'
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

echo "== 4. windowed hover run =="
# Boxes: hand y=0..100, ibeam y=100..200, arrow y=200..300. X held at 200.
# Sequence, one point per frame from frame 5:
#   f5  200,50   -> enter hand,  cursor=hand
#   f6  200,60   -> WITHIN hand  (must be SILENT)
#   f7  200,150  -> leave hand, enter ibeam, cursor=ibeam
#   f8  200,250  -> leave ibeam, enter arrow, cursor=arrow
#   f9  (leave)  -> leave arrow
LOG="$WORK/hover.log"
set +e
"$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name ENG09Hover \
  --width 400 --height 300 --frames 14 \
  --hover-after-frames "5:200,50;200,60;200,150;200,250;leave" > "$LOG" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { sed 's/^/   /' "$LOG" >&2; fail "windowed hover run exited $rc"; }

echo "== 5. assert enter/quiet/transition/leave + cursor shapes =="
# Pull the transition lines in order.
TRANS="$(grep -E 'rn-impeller: (hover_enter tag=|hover_leave tag=|cursor=)' "$LOG" || true)"
echo "$TRANS" | sed 's/^/   /'

# Resolve each box's tag from its hover_enter line, by the order they were hit.
HAND_TAG="$(echo "$TRANS" | sed -n 's/.*hover_enter tag=\([0-9]*\).*/\1/p' | sed -n 1p)"
IBEAM_TAG="$(echo "$TRANS" | sed -n 's/.*hover_enter tag=\([0-9]*\).*/\1/p' | sed -n 2p)"
ARROW_TAG="$(echo "$TRANS" | sed -n 's/.*hover_enter tag=\([0-9]*\).*/\1/p' | sed -n 3p)"
[ -n "$HAND_TAG" ] || fail "no hover_enter for the hand box — enter never fired"
[ -n "$IBEAM_TAG" ] || fail "no second hover_enter — transition to ibeam never fired"
[ -n "$ARROW_TAG" ] || fail "no third hover_enter — transition to arrow never fired"

# 1. THREE distinct tags: three disjoint boxes must not collapse to one.
UNIQ="$(printf '%s\n' "$HAND_TAG" "$IBEAM_TAG" "$ARROW_TAG" | sort -u | wc -l | tr -d ' ')"
[ "$UNIQ" -eq 3 ] || fail "three boxes returned $UNIQ distinct tags ($HAND_TAG/$IBEAM_TAG/$ARROW_TAG)"
echo "   OK: three distinct hovered tags $HAND_TAG/$IBEAM_TAG/$ARROW_TAG"

# 2. QUIET: exactly THREE hover_enter lines total. A per-move line would make
#    it four+ (the within-hand move at 200,60 must be silent).
ENTERS="$(echo "$TRANS" | grep -c 'hover_enter' || true)"
[ "$ENTERS" -eq 3 ] || fail "expected 3 hover_enter lines (enter is silent within a view), got $ENTERS — the per-move path is NOT quiet"
echo "   OK: exactly 3 enters — the within-view move was silent"

# 3. TRANSITION: leaving hand then ibeam then arrow. Expect leave hand + leave
#    ibeam + leave arrow (arrow's leave comes from the window-exit).
LEAVES="$(echo "$TRANS" | grep -c 'hover_leave' || true)"
[ "$LEAVES" -eq 3 ] || fail "expected 3 hover_leave lines (hand, ibeam, arrow-on-exit), got $LEAVES"
echo "   OK: 3 leaves — every entered box was left, including on window exit"

# 4. WINDOW-LEAVE: the LAST leave must be the arrow tag (the box hovered when
#    the cursor exited). Proves a control does not stay hovered after exit.
LAST_LEAVE="$(echo "$TRANS" | sed -n 's/.*hover_leave tag=\([0-9]*\).*/\1/p' | tail -1)"
[ "$LAST_LEAVE" = "$ARROW_TAG" ] || fail "last hover_leave was tag $LAST_LEAVE, expected arrow $ARROW_TAG — control stayed hovered after the cursor left the window"
echo "   OK: window-exit left the arrow box (tag $ARROW_TAG)"

# 5. CURSOR SHAPES: hand box -> cursor=hand, ibeam -> ibeam, arrow -> arrow,
#    in that order.
CURSORS="$(echo "$TRANS" | sed -n 's/.*cursor=\([a-z]*\).*/\1/p')"
C1="$(echo "$CURSORS" | sed -n 1p)"; C2="$(echo "$CURSORS" | sed -n 2p)"; C3="$(echo "$CURSORS" | sed -n 3p)"
[ "$C1" = "hand" ]  || fail "hand box (cursor:pointer) resolved cursor=$C1, expected hand"
[ "$C2" = "ibeam" ] || fail "ibeam box (cursor:text) resolved cursor=$C2, expected ibeam"
[ "$C3" = "arrow" ] || fail "arrow box (no cursor prop) resolved cursor=$C3, expected arrow"
echo "   OK: cursor shapes hand/ibeam/arrow resolved from ViewProps.cursor"

echo "HOVER_GATE_PASS (tags $HAND_TAG/$IBEAM_TAG/$ARROW_TAG, cursors $C1/$C2/$C3, enters=$ENTERS leaves=$LEAVES)"
