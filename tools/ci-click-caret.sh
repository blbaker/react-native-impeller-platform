#!/usr/bin/env bash
# desktop-input-gap item 3 GATE: click-to-caret in <TextInput>.
#
# A left click inside a field must put the caret at the codepoint boundary
# nearest the click x. Before item 3 every click left the caret at END.
#
# ⛔ THE CLICK TARGETS COME FROM THE PAINTED CARET, NOT FROM THE ENGINE'S OWN
# BOUNDARY REPORT. Arm P moves the caret with the KEYBOARD (Home + ArrowRight
# xK, the item-2a path) and reads the column the painter drew the bar at from
# a screenshot diff. Clicks are then aimed at fractions between two painted
# boundaries. If the gate aimed at the ti_glyph_x numbers instead, a bug that
# shifts BOTH the click mapping and that report (e.g. the text inset dropped
# from the click path) would click where the engine thinks glyphs are, map
# straight back, and pass while real users click one glyph off.
#
# Arms:
#   P   paint oracle: painted caret columns for boundaries 2 and 3 of field 1
#       ("abcdef") and 2 and 3 of field 2 ("a" e-acute "bc")
#   R   REAL XTest: click past end, type z, click 30% into b|c, type x ->
#       "abxcdefz" caret 3, onFocus fired ONCE (second click only moves caret)
#   A   synthetic click 30% into the b|c gap -> caret 2, ONSEL1 {2,2}, then X
#       -> "abXcdef"
#   B   synthetic click 70% into the b|c gap -> caret 3 (right half rounds up)
#   C   click left of the text -> 0; click past the end -> 6
#   D   field 2: click just after e-acute -> UTF-8 byte 3, UTF-16 selection 2
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
. "$CI_TOOLS/lib/wait-for.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item3-click-caret"
APP_NAME="Item3ClickCaret"

fail() { echo "CLICK_CARET_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/ClickCaretApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="clickcaretapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item3ClickCaret"; a.displayName="Click Caret Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 3 click-caret fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"
# RNI_BIN overrides the installed engine (sanitizer runs, FP-06).
[ -z "${RNI_BIN:-}" ] || RESOLVED="$RNI_BIN"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/click-caret.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/click-caret.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"


WIN_W=400
WIN_H=300
# Field 1: y 20..56, x 20..320. Field 2: y 76..112 (margins stack).
F1_Y=38
F2_Y=94
F1_BAND="21 55"
F2_BAND="77 111"

assert_scene_mounted() {  # $1 = log path
  local nodes
  nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$1" | tail -1)"
  [ -n "$nodes" ] || { tail -30 "$1" | sed 's/^/   /' >&2; fail "no 'scene_nodes=' line -- the app did not reach startSurface"; }
  [ "$nodes" -gt 0 ] \
    || fail "scene_nodes=$nodes -- the fixture mounted NOTHING (mismatched --app-name is the classic cause)"
}
caret_pos()  { sed -n 's/^rn-impeller: caret tag=[0-9-]* pos=\([0-9]*\) .*/\1/p' "$1" | tail -1; }
caret_text() { sed -n 's/^rn-impeller: caret tag=[0-9-]* pos=[0-9]* text=\(.*\)$/\1/p' "$1" | tail -1; }
sel_start()  { sed -n "s/^\[js\] ONSEL$2 start=\([0-9-]*\) end=[0-9-]*\$/\1/p" "$1" | tail -1; }
sel_end()    { sed -n "s/^\[js\] ONSEL$2 start=[0-9-]* end=\([0-9-]*\)\$/\1/p" "$1" | tail -1; }

run_win() {  # $1=log $2=frames $3...=extra args
  local log="$1" frames="$2"; shift 2
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name "$APP_NAME" \
      --width "$WIN_W" --height "$WIN_H" --frames "$frames" "$@" > "$log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -30 "$log" | sed 's/^/   /' >&2; fail "windowed run exited $rc ($log)"; }
  assert_scene_mounted "$log"
}

# Painted caret column after focusing field ($1 = y) and pressing Home then
# ArrowRight $2 times. $3 = band "y0 y1". Prints the column.
painted_col() {
  local fy="$1" k="$2" band="$3" tag="p-$1-$2" keys="10:Home:down" i
  for ((i = 0; i < k; i++)); do keys="$keys;ArrowRight:down"; done
  # FP-06: capture 3 frames after the last key (keys run one per frame from 10),
  # not at a ms deadline; a solid caret (RNI_CARET_BLINK_MS=0) so a slow frame
  # cannot land the capture in a blink-off phase.
  RNI_CARET_BLINK_MS=0 run_win "$WORK/$tag.log" $((10 + k + 1 + 8)) \
    --screenshot-first "$WORK/$tag-nofocus.ppm" \
    --click-after-frames "5:40,$fy" \
    --key-after-frames "$keys" \
    --screenshot "$WORK/$tag.ppm" --screenshot-after-frames $((10 + k + 1 + 3))
  [ -s "$WORK/$tag.ppm" ] || fail "P: no screenshot for $tag"
  set -- $band
  python3 "$CI_TOOLS/caret-pixel-diff.py" "$WORK/$tag-nofocus.ppm" "$WORK/$tag.ppm" 24 "$1" 320 "$2"
}
# x at fraction $3 of the way from column $1 to column $2 (1 decimal).
aim() { python3 -c 'import sys; a,b,f=map(float,sys.argv[1:4]); print("%.1f" % (a + f*(b-a)))' "$1" "$2" "$3"; }

echo "== P. paint oracle: painted caret columns from KEYBOARD moves =="
C2="$(painted_col $F1_Y 2 "$F1_BAND")"
C3="$(painted_col $F1_Y 3 "$F1_BAND")"
D2="$(painted_col $F2_Y 2 "$F2_BAND")"
D3="$(painted_col $F2_Y 3 "$F2_BAND")"
for v in "$C2" "$C3" "$D2" "$D3"; do
  [[ "$v" =~ ^[0-9]+$ ]] || fail "P: a painted caret column is not a number ('$C2' '$C3' '$D2' '$D3') -- no caret was painted after the keyboard move"
done
[ "$C3" -gt "$C2" ] && [ "$D3" -gt "$D2" ] \
  || fail "P: boundary 3 is not right of boundary 2 (field1 $C2,$C3 field2 $D2,$D3)"
echo "   OK: field1 b|c=$C2 c|d=$C3   field2 after-e-acute=$D2 next=$D3"
X_LEFT="$(aim "$C2" "$C3" 0.3)"
X_RIGHT="$(aim "$C2" "$C3" 0.7)"
X_EACUTE="$(aim "$D2" "$D3" 0.2)"

echo "== R. REAL XTest: click past end, type z, click at $X_LEFT, type x =="
XCLICK="$CI_TOOLS/xclick.py"
XKEY="$CI_TOOLS/xkey.py"
XPY=""
for cand in "${RNI_PYTHON:-}" python3 "$HOME/.cache/rni/xtest-venv/bin/python"; do
  [ -n "$cand" ] || continue
  command -v "$cand" > /dev/null 2>&1 || [ -x "$cand" ] || continue
  "$cand" -c 'from Xlib import display; from Xlib.ext import xtest; display.Display()' \
      > /dev/null 2>&1 || continue
  XPY="$cand"; break
done
if [ -z "$XPY" ]; then
  echo "CLICK_CARET_GATE_SKIP_R: no DISPLAY / python-xlib -- the REAL-click arm did not run."
else
  REAL_LOG="$WORK/real.log"
  # FP-06: each real event waits for the engine's caret line that proves the
  # previous one landed (no sleeps, no wall-clock run window), then a clean
  # --quit-on-term exit.
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name "$APP_NAME" \
      --width "$WIN_W" --height "$WIN_H" --idle-skip --quit-on-term \
      > "$REAL_LOG" 2>&1 &
  PID=$!
  rni_track "$PID"
  R1=1 R2=1 R3=1 R4=1 STEP=start
  step() {  # name ERE-the-engine-prints-after-it command...
    local name="$1" ere="$2"; shift 2
    "$@" > "$WORK/$name.log" 2>&1 || return 1
    rni_wait_line "$REAL_LOG" "$ere" 20 "$PID" || { STEP="$name (no line /$ere/)"; return 1; }
  }
  if rni_wait_line "$REAL_LOG" '^rn-impeller: first_present_ms=' 30 "$PID"; then
    step x1 '^rn-impeller: caret tag=[0-9-]* pos=6 text=abcdef$' "$XPY" "$XCLICK" "React Native (Impeller)" 300 $F1_Y && R1=0 &&
    step x2 '^rn-impeller: caret tag=[0-9-]* pos=7 text=abcdefz$' "$XPY" "$XKEY" "React Native (Impeller)" z && R2=0 &&
    step x3 '^rn-impeller: caret tag=[0-9-]* pos=2 text=abcdefz$' "$XPY" "$XCLICK" "React Native (Impeller)" "$X_LEFT" $F1_Y && R3=0 &&
    step x4 '^rn-impeller: caret tag=[0-9-]* pos=3 text=abxcdefz$' "$XPY" "$XKEY" "React Native (Impeller)" x && R4=0
  else
    STEP="first present"
  fi
  kill -TERM "$PID" 2> /dev/null
  rni_wait_exit "$PID" 60; APPRC=$?
  set -e
  [ "$R1$R2$R3$R4" = "0000" ] || { cat "$WORK"/x?.log | sed 's/^/   /' >&2; grep -E 'caret tag|textinput_focus' "$REAL_LOG" | sed 's/^/   /' >&2; fail "R: real event step failed at $STEP ($R1$R2$R3$R4)"; }
  [ "$APPRC" -eq 0 ] || { tail -30 "$REAL_LOG" | sed 's/^/   /' >&2; fail "windowed app exited $APPRC"; }
  assert_scene_mounted "$REAL_LOG"
  R_TEXT="$(caret_text "$REAL_LOG")"; R_POS="$(caret_pos "$REAL_LOG")"
  [ "$R_TEXT" = "abxcdefz" ] && [ "$R_POS" = "3" ] \
    || { grep -E 'caret tag|ti_glyph_x|textinput_focus' "$REAL_LOG" | sed 's/^/   /' >&2; fail "R: REAL click-type-click-type should give 'abxcdefz' caret 3; got '$R_TEXT' caret $R_POS -- a click did not move the caret, or the second click re-seeded the buffer"; }
  NFOCUS="$(grep -c '^\[js\] ONFOCUS1$' "$REAL_LOG" || true)"
  [ "$NFOCUS" = "1" ] || fail "R: onFocus fired $NFOCUS times for two clicks on the same field; a click on the already-focused field must only move the caret"
  echo "   OK: REAL clicks -> 'abxcdefz' caret 3, onFocus once"
fi

echo "== A. synthetic click at $X_LEFT (30% into b|c) -> caret 2, then X =="
run_win "$WORK/a.log" 60 --click-after-frames "5:$X_LEFT,$F1_Y" --char-after-frames "12:88"
A_TEXT="$(caret_text "$WORK/a.log")"; A_POS="$(caret_pos "$WORK/a.log")"
[ "$A_TEXT" = "abXcdef" ] && [ "$A_POS" = "3" ] \
  || { grep -E 'caret tag|ti_glyph_x' "$WORK/a.log" | sed 's/^/   /' >&2; fail "A: click 30% into b|c then X should give 'abXcdef' caret 3; got '$A_TEXT' caret $A_POS"; }
grep -q '^\[js\] ONSEL1 start=2 end=2$' "$WORK/a.log" \
  || fail "A: the click did not report onSelectionChange {2,2}"
echo "   OK: click -> {2,2}, X -> 'abXcdef'"

echo "== B. synthetic click at $X_RIGHT (70% into b|c) -> caret 3 =="
run_win "$WORK/b.log" 40 --click-after-frames "5:$X_RIGHT,$F1_Y"
B_POS="$(caret_pos "$WORK/b.log")"
[ "$B_POS" = "3" ] || fail "B: a click on the RIGHT half of 'c' should put the caret after it (3); got $B_POS"
echo "   OK: right half -> 3"

echo "== C. before-start and past-end clicks =="
run_win "$WORK/c1.log" 40 --click-after-frames "5:21,$F1_Y"
run_win "$WORK/c2.log" 40 --click-after-frames "5:300,$F1_Y"
C1="$(caret_pos "$WORK/c1.log")"; C2P="$(caret_pos "$WORK/c2.log")"
[ "$C1" = "0" ] || fail "C: a click left of the text should give caret 0; got $C1"
[ "$C2P" = "6" ] || fail "C: a click past the end should give caret 6; got $C2P"
echo "   OK: left of text -> 0, past end -> 6"

echo "== D. field 2: click just after e-acute ($X_EACUTE) -> byte 3, UTF-16 2 =="
run_win "$WORK/d.log" 40 --click-after-frames "5:$X_EACUTE,$F2_Y"
D_POS="$(caret_pos "$WORK/d.log")"
[ "$D_POS" = "3" ] || fail "D: after 'a'+e-acute the caret is UTF-8 byte 3; got $D_POS"
[ "$(sel_start "$WORK/d.log" 2)" = "2" ] && [ "$(sel_end "$WORK/d.log" 2)" = "2" ] \
  || fail "D: onSelectionChange should be UTF-16 {2,2}; got {$(sel_start "$WORK/d.log" 2),$(sel_end "$WORK/d.log" 2)}"
echo "   OK: byte 3, selection {2,2}"

echo "CLICK_CARET_GATE_PASS (click-to-caret: nearest boundary, left/right half, clamps, UTF-8, re-click keeps text)"
