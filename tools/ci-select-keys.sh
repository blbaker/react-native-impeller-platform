#!/usr/bin/env bash
# desktop-input-gap item 4a GATE: KEYBOARD selection in <TextInput>.
#
# Shift + any caret move extends a selection from a fixed anchor; select-all
# is Ctrl+A on Linux/Windows (Cmd+A on darwin); typing / Backspace / Delete
# with a selection replace or delete the selected range; a plain Left/Right
# collapses a selection to its near edge; onSelectionChange reports ordered
# {start,end} in UTF-16 units; the highlight is painted behind the run.
#
# Arms:
#   a  End, Shift+Left x3 -> {3,6}; type X -> 'abcX' caret 4
#   b  Ctrl+A, Backspace -> ''
#   c  Shift+Home, Delete -> ''
#   d  with {3,6}: plain Left -> caret 3 collapsed; plain Right -> caret 6
#   e  field 2 'abc def': Shift+Ctrl+Left from end -> {4,7}
#   f  REAL XTest: End, Shift+Left, Shift+Left -> anchor 6 caret 4
#   g  PIXEL: with {3,6}, highlight pixels lie between the painted caret
#      columns of boundaries 3 and 6, and none left of boundary 3
#
# Every field is focused with a click PAST the end of its text, so item 3's
# click-to-caret leaves the caret at the end.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item4a-select-keys"
APP_NAME="Item4aSelectKeys"

fail() { echo "SELECT_KEYS_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/SelectKeysApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="selectkeysapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item4aSelectKeys"; a.displayName="Select Keys Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 4a select-keys fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/react-native-impeller-platform/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/select-keys.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/select-keys.bundle"
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
  run_win "$WORK/$tag.log" 600 \
    --screenshot-first "$WORK/$tag-nofocus.ppm" \
    --click-after-frames "5:40,$fy" \
    --key-after-frames "$keys" \
    --screenshot "$WORK/$tag.ppm" --screenshot-after 150
  [ -s "$WORK/$tag.ppm" ] || fail "P: no screenshot for $tag"
  set -- $band
  python3 "$CI_TOOLS/caret-pixel-diff.py" "$WORK/$tag-nofocus.ppm" "$WORK/$tag.ppm" 24 "$1" 320 "$2"
}
# x at fraction $3 of the way from column $1 to column $2 (1 decimal).
aim() { python3 -c 'import sys; a,b,f=map(float,sys.argv[1:4]); print("%.1f" % (a + f*(b-a)))' "$1" "$2" "$3"; }


WIN_W=400
WIN_H=300
F1_XY="300,38"
F2_XY="300,94"

assert_scene_mounted() {  # $1 = log path
  local nodes
  nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$1" | tail -1)"
  [ -n "$nodes" ] || { tail -30 "$1" | sed 's/^/   /' >&2; fail "no 'scene_nodes=' line -- the app did not reach startSurface"; }
  [ "$nodes" -gt 0 ] \
    || fail "scene_nodes=$nodes -- the fixture mounted NOTHING (mismatched --app-name is the classic cause)"
}
caret_pos()  { sed -n 's/^rn-impeller: caret tag=[0-9-]* pos=\([0-9]*\) .*/\1/p' "$1" | tail -1; }
caret_text() { sed -n 's/^rn-impeller: caret tag=[0-9-]* pos=[0-9]* text=\(.*\)$/\1/p' "$1" | tail -1; }
sel_line()   { sed -n 's/^rn-impeller: selection tag=[0-9-]* \(anchor=[0-9]* caret=[0-9]*\)$/\1/p' "$1" | tail -1; }
onsel_last() { sed -n "s/^\[js\] ONSEL$2 \(start=[0-9-]* end=[0-9-]*\)\$/\1/p" "$1" | tail -1; }
onsel_nth()  { sed -n "s/^\[js\] ONSEL$2 \(start=[0-9-]* end=[0-9-]*\)\$/\1/p" "$1" | sed -n "${3}p"; }

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
dump() { grep -E 'caret tag|selection tag|ONSEL|ONCHANGE' "$1" | sed 's/^/   /' >&2; }

echo "== a. End, Shift+Left x3 -> {3,6}; type X -> 'abcX' =="
run_win "$WORK/a.log" 60 --click-after-frames "5:$F1_XY" \
  --key-after-frames "10:End:down;ArrowLeft:down:shift;ArrowLeft:down:shift;ArrowLeft:down:shift" \
  --char-after-frames "14:88"
# ONSEL1 sequence: click(6,6) End(6,6) {5,6} {4,6} {3,6} then X -> {4,4}
A_SEL="$(onsel_nth "$WORK/a.log" 1 5)"
[ "$A_SEL" = "start=3 end=6" ] \
  || { dump "$WORK/a.log"; fail "a: Shift+Left x3 from the end should select {3,6}; got '$A_SEL' -- Shift is not extending a selection from a fixed anchor"; }
A_TEXT="$(caret_text "$WORK/a.log")"; A_POS="$(caret_pos "$WORK/a.log")"
[ "$A_TEXT" = "abcX" ] && [ "$A_POS" = "4" ] \
  || { dump "$WORK/a.log"; fail "a: typing X over the selection {3,6} should give 'abcX' caret 4; got '$A_TEXT' caret $A_POS -- typing does not replace the selection"; }
[ "$(onsel_last "$WORK/a.log" 1)" = "start=4 end=4" ] \
  || fail "a: after replacing, the selection should collapse to {4,4}; got '$(onsel_last "$WORK/a.log" 1)'"
echo "   OK: {3,6} then X -> 'abcX' caret 4, selection {4,4}"

echo "== b. select-all (Ctrl+A), Backspace -> '' =="
run_win "$WORK/b.log" 60 --click-after-frames "5:$F1_XY" \
  --key-after-frames "10:a:down:ctrl;Backspace:down"
B_ALL="$(onsel_nth "$WORK/b.log" 1 2)"
[ "$B_ALL" = "start=0 end=6" ] \
  || { dump "$WORK/b.log"; fail "b: select-all should report {0,6}; got '$B_ALL' -- select-all is not bound to this platform's modifier"; }
B_TEXT="$(caret_text "$WORK/b.log")"
[ -z "$B_TEXT" ] && [ "$(caret_pos "$WORK/b.log")" = "0" ] \
  || { dump "$WORK/b.log"; fail "b: Backspace after select-all should empty the field; got '$B_TEXT' -- Backspace does not delete the selection"; }
echo "   OK: {0,6} then Backspace -> '' caret 0"

echo "== c. Shift+Home, Delete -> '' =="
run_win "$WORK/c.log" 60 --click-after-frames "5:$F1_XY" \
  --key-after-frames "10:Home:down:shift;Delete:down"
[ "$(onsel_nth "$WORK/c.log" 1 2)" = "start=0 end=6" ] \
  || { dump "$WORK/c.log"; fail "c: Shift+Home from the end should select {0,6}; got '$(onsel_nth "$WORK/c.log" 1 2)' -- Shift is not extending a selection from a fixed anchor"; }
C_TEXT="$(caret_text "$WORK/c.log")"
[ -z "$C_TEXT" ] || { dump "$WORK/c.log"; fail "c: forward Delete with {0,6} selected should empty the field; got '$C_TEXT'"; }
echo "   OK: {0,6} then Delete -> ''"

echo "== d. plain Left / Right collapse a selection to its near edge =="
run_win "$WORK/d1.log" 60 --click-after-frames "5:$F1_XY" \
  --key-after-frames "10:ArrowLeft:down:shift;ArrowLeft:down:shift;ArrowLeft:down:shift;ArrowLeft:down"
run_win "$WORK/d2.log" 60 --click-after-frames "5:$F1_XY" \
  --key-after-frames "10:ArrowLeft:down:shift;ArrowLeft:down:shift;ArrowLeft:down:shift;ArrowRight:down"
D1="$(sel_line "$WORK/d1.log")"; D2="$(sel_line "$WORK/d2.log")"
[ "$D1" = "anchor=3 caret=3" ] \
  || { dump "$WORK/d1.log"; fail "d: plain Left with {3,6} selected should collapse to 3; got '$D1'"; }
[ "$D2" = "anchor=6 caret=6" ] \
  || { dump "$WORK/d2.log"; fail "d: plain Right with {3,6} selected should collapse to 6; got '$D2'"; }
echo "   OK: Left -> 3, Right -> 6"

echo "== e. field 2 'abc def': Shift+Ctrl+Left from the end -> {4,7} =="
run_win "$WORK/e.log" 60 --click-after-frames "5:$F2_XY" \
  --key-after-frames "10:ArrowLeft:down:shift,ctrl"
[ "$(onsel_last "$WORK/e.log" 2)" = "start=4 end=7" ] \
  || { dump "$WORK/e.log"; fail "e: Shift+word-left from the end of 'abc def' should select {4,7}; got '$(onsel_last "$WORK/e.log" 2)' -- Shift is not extending a selection from a fixed anchor"; }
echo "   OK: {4,7}"

echo "== f. REAL XTest: End, Shift+Left, Shift+Left -> anchor 6 caret 4 =="
XKEY="$CI_TOOLS/xkey.py"
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
  echo "SELECT_KEYS_GATE_SKIP_F: no DISPLAY / python-xlib -- the REAL-key arm did not run."
else
  REAL_LOG="$WORK/real.log"
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name "$APP_NAME" \
      --width "$WIN_W" --height "$WIN_H" --idle-skip --idle-run-sec 10 \
      > "$REAL_LOG" 2>&1 &
  PID=$!
  sleep 4
  "$XPY" "$XCLICK" "React Native (Impeller)" 300 38 > "$WORK/xc.log" 2>&1; R1=$?
  "$XPY" "$XKEY" "React Native (Impeller)" End Left+shift Left+shift > "$WORK/xk.log" 2>&1; R2=$?
  wait "$PID"; APPRC=$?
  set -e
  [ "$R1$R2" = "00" ] || { cat "$WORK/xc.log" "$WORK/xk.log" | sed 's/^/   /' >&2; fail "f: XTest driver failed ($R1$R2)"; }
  [ "$APPRC" -eq 0 ] || { tail -30 "$REAL_LOG" | sed 's/^/   /' >&2; fail "f: windowed app exited $APPRC"; }
  assert_scene_mounted "$REAL_LOG"
  F_SEL="$(sel_line "$REAL_LOG")"
  [ "$F_SEL" = "anchor=6 caret=4" ] \
    || { dump "$REAL_LOG"; fail "f: REAL End+Shift+Left x2 should leave anchor=6 caret=4; got '$F_SEL' -- Shift is not extending a selection from a fixed anchor"; }
  echo "   OK: REAL keys -> anchor 6 caret 4"
fi

echo "== g. PIXEL: highlight between painted boundaries 3 and 6 =="
# Painted caret columns for boundaries 3 and 6 (collapsed, keyboard-moved),
# then a frame with {3,6} selected. Highlight = pixels that differ from the
# unfocused frame, inside the field band, with a blue-dominant colour.
run_win "$WORK/g3.log" 600 --screenshot-first "$WORK/g-nofocus.ppm" \
  --click-after-frames "5:$F1_XY" --key-after-frames "10:ArrowLeft:down;ArrowLeft:down;ArrowLeft:down" \
  --screenshot "$WORK/g3.ppm" --screenshot-after 150
run_win "$WORK/g6.log" 600 --screenshot-first "$WORK/g6-nofocus.ppm" \
  --click-after-frames "5:$F1_XY" \
  --screenshot "$WORK/g6.ppm" --screenshot-after 150
run_win "$WORK/gs.log" 600 --click-after-frames "5:$F1_XY" \
  --key-after-frames "10:ArrowLeft:down:shift;ArrowLeft:down:shift;ArrowLeft:down:shift" \
  --screenshot "$WORK/gs.ppm" --screenshot-after 150
COL3="$(python3 "$CI_TOOLS/caret-pixel-diff.py" "$WORK/g-nofocus.ppm" "$WORK/g3.ppm" 24 21 320 55)"
COL6="$(python3 "$CI_TOOLS/caret-pixel-diff.py" "$WORK/g6-nofocus.ppm" "$WORK/g6.ppm" 24 21 320 55)"
[[ "$COL3" =~ ^[0-9]+$ && "$COL6" =~ ^[0-9]+$ ]] || fail "g: no painted caret column ($COL3 / $COL6)"
HL="$(python3 "$CI_TOOLS/selection-pixels.py" "$WORK/g-nofocus.ppm" "$WORK/gs.ppm" 21 55 "$COL3" "$COL6")"
echo "   highlight probe: $HL (boundary 3 at x=$COL3, 6 at x=$COL6)"
case "$HL" in
  INSIDE=0\ *) fail "g: no highlight pixels between boundaries 3 and 6 ($HL) -- the selection is not painted" ;;
esac
OUTSIDE="$(echo "$HL" | sed -n 's/.*OUTSIDE_LEFT=\([0-9]*\).*/\1/p')"
[ "$OUTSIDE" = "0" ] || fail "g: highlight pixels found LEFT of boundary 3 ($HL) -- the highlight extent is wrong"
echo "   OK: highlight painted inside [$COL3,$COL6), none left of it"

echo "SELECT_KEYS_GATE_PASS (Shift+moves extend, select-all, replace/delete selection, collapse, UTF-16 ranges, painted highlight)"
