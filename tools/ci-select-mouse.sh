#!/usr/bin/env bash
# desktop-input-gap item 4b GATE: MOUSE selection in <TextInput>.
#
# Press-drag-release selects from the press point to the release point;
# Shift+click extends from the existing anchor; a double click selects the
# word under the pointer and a triple click the whole (single) line; a double
# click held and dragged grows by whole words. Clicks further than 4 px apart
# are separate single clicks, not a double click.
#
# Aim points are glyph boundaries from the engine's ti_glyph_x report. That is
# safe HERE because ci-click-caret.sh already proves click -> boundary mapping
# against the PAINTED caret; this gate tests what happens on top of it.
#
# Arms (field 1 'abcdef', field 2 'abc def ghi'):
#   a  drag boundary 1 -> 4                -> anchor 1 caret 4, ONSEL {1,4}
#   b  reverse drag 5 -> 2                 -> anchor 5 caret 2, ONSEL {2,5}
#   c  click at 1, Shift+click at 4        -> anchor 1 caret 4
#   d  double click inside 'def'           -> {4,7}
#   e  triple click inside field 1         -> {0,6}
#   f  double click 'def', hold, drag onto 'ghi' -> {4,11}
#   g  two clicks 10 px apart              -> a caret, NOT a word
#   h  REAL XTest drag 1 -> 4 on field 1, then REAL double click on 'def'
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item4b-select-mouse"
APP_NAME="Item4bSelectMouse"

fail() { echo "SELECT_MOUSE_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/SelectMouseApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="selectmouseapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item4bSelectMouse"; a.displayName="Select Mouse Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 4b select-mouse fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/react-native-impeller-platform/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/select-mouse.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/select-mouse.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"



WIN_W=400
WIN_H=300
F1_Y=38
F2_Y=94

assert_scene_mounted() {  # $1 = log path
  local nodes
  nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$1" | tail -1)"
  [ -n "$nodes" ] || { tail -30 "$1" | sed 's/^/   /' >&2; fail "no 'scene_nodes=' line -- the app did not reach startSurface"; }
  [ "$nodes" -gt 0 ] \
    || fail "scene_nodes=$nodes -- the fixture mounted NOTHING (mismatched --app-name is the classic cause)"
}
sel_line()   { sed -n 's/^rn-impeller: selection tag=[0-9-]* \(anchor=[0-9]* caret=[0-9]*\).*$/\1/p' "$1" | tail -1; }
onsel_last() { sed -n "s/^\[js\] ONSEL$2 \(start=[0-9-]* end=[0-9-]*\)\$/\1/p" "$1" | tail -1; }
dump() { grep -E 'selection tag|ONSEL|textinput_focus|mouse_requested' "$1" | sed 's/^/   /' >&2; }

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

echo "== 0. glyph boundaries (ti_glyph_x) for both fields =="
run_win "$WORK/probe1.log" 40 --click-after-frames "5:300,$F1_Y"
run_win "$WORK/probe2.log" 40 --click-after-frames "5:300,$F2_Y"
XS1="$(sed -n 's/^rn-impeller: ti_glyph_x tag=[0-9]* xs=//p' "$WORK/probe1.log" | tail -1)"
XS2="$(sed -n 's/^rn-impeller: ti_glyph_x tag=[0-9]* xs=//p' "$WORK/probe2.log" | tail -1)"
IFS=, read -r -a B1 <<< "$XS1"
IFS=, read -r -a B2 <<< "$XS2"
[ "${#B1[@]}" = "7" ] && [ "${#B2[@]}" = "12" ] \
  || fail "0: expected 7 boundaries for 'abcdef' and 12 for 'abc def ghi'; got ${#B1[@]} and ${#B2[@]} ('$XS1' / '$XS2')"
mid() { python3 -c 'import sys; print("%.1f" % ((float(sys.argv[1]) + float(sys.argv[2])) / 2))' "$1" "$2"; }
DEF_X="$(mid "${B2[5]}" "${B2[6]}")"   # inside 'e' of 'def'
GHI_X="$(mid "${B2[9]}" "${B2[10]}")"  # inside 'h' of 'ghi'
MID1="$(mid "${B1[2]}" "${B1[3]}")"    # inside 'c'
echo "   field1 xs=$XS1"
echo "   field2 xs=$XS2"

echo "== a. drag boundary 1 -> 4 =="
run_win "$WORK/a.log" 60 --mouse-after-frames \
  "8:down@${B1[1]},$F1_Y;move@${B1[2]},$F1_Y;move@${B1[4]},$F1_Y;up@${B1[4]},$F1_Y"
[ "$(sel_line "$WORK/a.log")" = "anchor=1 caret=4" ] && [ "$(onsel_last "$WORK/a.log" 1)" = "start=1 end=4" ] \
  || { dump "$WORK/a.log"; fail "a: a drag from boundary 1 to 4 should select {1,4}; got '$(sel_line "$WORK/a.log")' / '$(onsel_last "$WORK/a.log" 1)' -- dragging does not extend a selection"; }
echo "   OK: {1,4}"

echo "== b. reverse drag 5 -> 2 =="
run_win "$WORK/b.log" 60 --mouse-after-frames \
  "8:down@${B1[5]},$F1_Y;move@${B1[3]},$F1_Y;move@${B1[2]},$F1_Y;up@${B1[2]},$F1_Y"
[ "$(sel_line "$WORK/b.log")" = "anchor=5 caret=2" ] && [ "$(onsel_last "$WORK/b.log" 1)" = "start=2 end=5" ] \
  || { dump "$WORK/b.log"; fail "b: a leftward drag from 5 to 2 should give anchor 5 caret 2, ONSEL {2,5}; got '$(sel_line "$WORK/b.log")' / '$(onsel_last "$WORK/b.log" 1)' -- dragging does not extend a selection"; }
echo "   OK: anchor 5 caret 2, {2,5}"

echo "== c. click at 1, Shift+click at 4 =="
run_win "$WORK/c.log" 60 --mouse-after-frames \
  "8:down@${B1[1]},$F1_Y;up@${B1[1]},$F1_Y;sdown@${B1[4]},$F1_Y;up@${B1[4]},$F1_Y"
[ "$(sel_line "$WORK/c.log")" = "anchor=1 caret=4" ] \
  || { dump "$WORK/c.log"; fail "c: Shift+click at 4 after a click at 1 should select {1,4}; got '$(sel_line "$WORK/c.log")' -- Shift+click does not extend, or the distant second press was counted as a double click"; }
echo "   OK: {1,4}"

echo "== d. double click inside 'def' =="
run_win "$WORK/d.log" 60 --mouse-after-frames \
  "8:down@$DEF_X,$F2_Y;up@$DEF_X,$F2_Y;down@$DEF_X,$F2_Y;up@$DEF_X,$F2_Y"
[ "$(onsel_last "$WORK/d.log" 2)" = "start=4 end=7" ] \
  || { dump "$WORK/d.log"; fail "d: a double click inside 'def' should select the word {4,7}; got '$(onsel_last "$WORK/d.log" 2)' -- double click does not select a word"; }
echo "   OK: {4,7}"

echo "== e. triple click inside field 1 =="
run_win "$WORK/e.log" 60 --mouse-after-frames \
  "8:down@$MID1,$F1_Y;up@$MID1,$F1_Y;down@$MID1,$F1_Y;up@$MID1,$F1_Y;down@$MID1,$F1_Y;up@$MID1,$F1_Y"
[ "$(onsel_last "$WORK/e.log" 1)" = "start=0 end=6" ] \
  || { dump "$WORK/e.log"; fail "e: a triple click should select the whole line {0,6}; got '$(onsel_last "$WORK/e.log" 1)' -- triple click does not select the line"; }
echo "   OK: {0,6}"

echo "== f. double click 'def', hold, drag onto 'ghi' =="
run_win "$WORK/f.log" 60 --mouse-after-frames \
  "8:down@$DEF_X,$F2_Y;up@$DEF_X,$F2_Y;down@$DEF_X,$F2_Y;move@$GHI_X,$F2_Y;up@$GHI_X,$F2_Y"
[ "$(onsel_last "$WORK/f.log" 2)" = "start=4 end=11" ] \
  || { dump "$WORK/f.log"; fail "f: double-click-drag from 'def' onto 'ghi' should select whole words {4,11}; got '$(onsel_last "$WORK/f.log" 2)' -- double click does not select a word, or word-drag does not grow by words"; }
echo "   OK: {4,11}"

echo "== g. two clicks 10 px apart are two single clicks =="
G2="$(python3 -c 'import sys; print("%.1f" % (float(sys.argv[1]) + 10))' "$MID1")"
run_win "$WORK/g.log" 60 --mouse-after-frames \
  "8:down@$MID1,$F1_Y;up@$MID1,$F1_Y;down@$G2,$F1_Y;up@$G2,$F1_Y"
G_SEL="$(onsel_last "$WORK/g.log" 1)"
case "$G_SEL" in
  "start="*) S="${G_SEL#start=}"; S="${S%% *}"; E="${G_SEL##*end=}"
             [ "$S" = "$E" ] || { dump "$WORK/g.log"; fail "g: two clicks 10 px apart should leave a caret, got a selection '$G_SEL' -- distant clicks are counted as a double click" ; } ;;
  *) fail "g: no ONSEL1 line" ;;
esac
echo "   OK: caret at $S"

echo "== h. REAL XTest drag on field 1, then REAL double click on 'def' =="
XDRAG="$CI_TOOLS/xdrag.py"
XPY=""
for cand in "${RNI_PYTHON:-}" python3 "$HOME/.cache/rni/xtest-venv/bin/python"; do
  [ -n "$cand" ] || continue
  command -v "$cand" > /dev/null 2>&1 || [ -x "$cand" ] || continue
  "$cand" -c 'from Xlib import display; from Xlib.ext import xtest; display.Display()' \
      > /dev/null 2>&1 || continue
  XPY="$cand"; break
done
if [ -z "$XPY" ]; then
  echo "SELECT_MOUSE_GATE_SKIP_H: no DISPLAY / python-xlib -- the REAL-pointer arm did not run."
else
  REAL_LOG="$WORK/real.log"
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name "$APP_NAME" \
      --width "$WIN_W" --height "$WIN_H" --idle-skip --idle-run-sec 10 \
      > "$REAL_LOG" 2>&1 &
  PID=$!
  sleep 4
  "$XPY" "$XDRAG" "React Native (Impeller)" "drag:${B1[1]},$F1_Y:${B1[4]},$F1_Y" > "$WORK/xd1.log" 2>&1; R1=$?
  sleep 0.3
  "$XPY" "$XDRAG" "React Native (Impeller)" "dbl:$DEF_X,$F2_Y" > "$WORK/xd2.log" 2>&1; R2=$?
  wait "$PID"; APPRC=$?
  set -e
  [ "$R1$R2" = "00" ] || { cat "$WORK"/xd?.log | sed 's/^/   /' >&2; fail "h: XTest driver failed ($R1$R2)"; }
  [ "$APPRC" -eq 0 ] || { tail -30 "$REAL_LOG" | sed 's/^/   /' >&2; fail "h: windowed app exited $APPRC"; }
  assert_scene_mounted "$REAL_LOG"
  H1="$(sed -n "s/^\[js\] ONSEL1 \(start=[0-9-]* end=[0-9-]*\)\$/\1/p" "$REAL_LOG" | tail -1)"
  H2="$(onsel_last "$REAL_LOG" 2)"
  [ "$H1" = "start=1 end=4" ] \
    || { dump "$REAL_LOG"; fail "h: REAL drag 1 -> 4 should select {1,4}; got '$H1' -- dragging does not extend a selection"; }
  [ "$H2" = "start=4 end=7" ] \
    || { dump "$REAL_LOG"; fail "h: REAL double click on 'def' should select {4,7}; got '$H2' -- double click does not select a word"; }
  echo "   OK: REAL drag {1,4}, REAL double click {4,7}"
fi

echo "SELECT_MOUSE_GATE_PASS (drag, reverse drag, Shift+click, double/triple click, word drag, click slop)"
