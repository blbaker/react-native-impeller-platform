#!/usr/bin/env bash
# desktop-input-gap item 2a GATE: a real caret in single-line TextInput --
# arrow/word/line movement, forward Delete, edit-at-caret, and UTF-8 typing.
#
# ⛔ WHY THIS GATE EXISTS ON TOP OF ci-textedit.sh / ci-key-events.sh.
# ci-textedit.sh proves typing/Backspace/Enter/onChangeText through the
# headless --type harness, but every edit in it lands at the END of the
# buffer (FabricHost.cpp used to hardcode `caret = value.size()` on every
# call) -- it never moves the caret and never asserts an edit lands anywhere
# but the end. ci-key-events.sh proves ArrowLeft/Tab/Escape/Delete/modifiers
# REACH JS (onKeyDown/onKeyUp/onKeyPress), but never asserts any of them
# actually MOVE anything -- a caret pinned to end could pass it unchanged.
# This gate is the first to assert: (a) InsertChar/Backspace/DeleteForward
# act AT THE CARET, not the end; (b) arrow/word/Home/End actually move it;
# (c) typing is full UTF-8, not the old 0x20-0x7E ASCII filter; (d) the
# PAINTED caret moves with it, not just the logical index; (e)
# onSelectionChange fires in UTF-16 code units, RN's own convention.
#
# ⛔ THE TWO ASSERTION HALVES ARE NOT INTERCHANGEABLE -- same discipline as
# ci-key-events.sh/ci-window-input.sh:
#   R. REAL key events (XTest via tools/xkey.py) for the registration arm --
#      only this can die if the caret-routing branch in dispatchKeyEvent is
#      never reached from a real glfwSetKeyCallback.
#   A-E. SYNTHETIC events (--key-after-frames / --char-after-frames) for the
#      full behavioural matrix (word move, UTF-8, pixel position) on hosts
#      where XTest cannot easily synthesise every codepoint (emoji has no
#      physical key on any layout).
#
# ⚠️ ASSERTS scene_nodes>0 and the exact --app-name in every arm
# (acceptance-gate-instrument-validation's "mismatched --app-name mounts
# nothing and naive checks pass" pitfall).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/eng2a-caret"
APP_NAME="Eng2aCaret"

fail() { echo "CARET_EDIT_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/CaretApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="caretapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Eng2aCaret"; a.displayName="Caret Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 2a caret fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/caret.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/caret.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"

WIN_W=400
WIN_H=300
# Field 1 (defaultValue "abcdef"): marginTop:20 marginLeft:20, 300x36.
F1_XY="40,38"
# Field 2 (defaultValue "abc def", word-move arm): marginTop:20 BELOW field 1
# (margins stack in a column: 20+36+20 = y 76..112), marginLeft:20.
F2_XY="40,94"

assert_scene_mounted() {  # $1 = log path
  local nodes
  nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$1" | tail -1)"
  [ -n "$nodes" ] || { tail -30 "$1" | sed 's/^/   /' >&2; fail "no 'scene_nodes=' line -- the app did not reach startSurface"; }
  [ "$nodes" -gt 0 ] \
    || fail "scene_nodes=$nodes -- the fixture mounted NOTHING (mismatched --app-name is the classic cause)"
}

# Last `rn-impeller: caret tag=N pos=K text=...` line's pos= / text= fields.
caret_pos()  { sed -n 's/^rn-impeller: caret tag=[0-9-]* pos=\([0-9]*\) .*/\1/p' "$1" | tail -1; }
caret_text() { sed -n 's/^rn-impeller: caret tag=[0-9-]* pos=[0-9]* text=\(.*\)$/\1/p' "$1" | tail -1; }
# Last ONSEL1/ONSEL2 start/end (UTF-16 units) and ONCHANGE1/ONCHANGE2 text.
sel1_start() { sed -n 's/^\[js\] ONSEL1 start=\([0-9-]*\) end=[0-9-]*$/\1/p' "$1" | tail -1; }
sel1_end()   { sed -n 's/^\[js\] ONSEL1 start=[0-9-]* end=\([0-9-]*\)$/\1/p' "$1" | tail -1; }
change1_last(){ sed -n 's/^\[js\] ONCHANGE1 text=\(.*\)$/\1/p' "$1" | tail -1; }
change1_nth() {  # $1=log $2=1-based occurrence
  sed -n 's/^\[js\] ONCHANGE1 text=\(.*\)$/\1/p' "$1" | sed -n "${2}p"
}

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

echo "== R. REAL XTest: End, Left x3 on field 1 -> caret pos=3 (native-side) =="
XKEY="$CI_TOOLS/xkey.py"
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
[ -f "$XKEY" ] || XTEST_OK=0

if [ "$XTEST_OK" = "0" ]; then
  echo "CARET_EDIT_GATE_SKIP_R: no DISPLAY / python-xlib -- the REAL-XTest arm did"
  echo "  not run. The synthetic arms below cannot detect a caret-routing"
  echo "  branch that is unreachable from a real glfwSetKeyCallback."
else
  REAL_LOG="$WORK/real-caret.log"
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name "$APP_NAME" \
      --width "$WIN_W" --height "$WIN_H" --idle-skip --idle-run-sec 12 \
      --click-after-frames "5:${F1_XY}" \
      > "$REAL_LOG" 2>&1 &
  PID=$!
  sleep 4
  "$XPY" "$XKEY" "React Native (Impeller)" "End" "Left" "Left" "Left" \
      > "$WORK/xkey-caret.log" 2>&1
  XRC=$?
  wait "$PID"
  APPRC=$?
  set -e
  sed 's/^/   /' "$WORK/xkey-caret.log"
  [ "$XRC" -eq 0 ] || { tail -20 "$WORK/xkey-caret.log" | sed 's/^/   /' >&2; fail "XTest key driver failed (rc=$XRC)"; }
  [ "$APPRC" -eq 0 ] || { tail -30 "$REAL_LOG" | sed 's/^/   /' >&2; fail "windowed app exited $APPRC"; }
  assert_scene_mounted "$REAL_LOG"
  RPOS="$(caret_pos "$REAL_LOG")"
  [ "$RPOS" = "3" ] \
    || { tail -40 "$REAL_LOG" | sed 's/^/   /' >&2; fail "REAL XTest End+Left x3 left caret at pos=$RPOS, want 3 -- the caret-routing branch in dispatchKeyEvent never fired for a REAL key press (the unregistered/unreachable-branch bug this arm exists to catch)"; }
  echo "   OK: REAL XTest End+Left,Left,Left -> caret pos=3"
fi

echo "== A. synthetic: End, Left x3, type 'X' -> 'abcXdef', selection {4,4} =="
LOG_A="$WORK/arm-a.log"
run_win "$LOG_A" 60 \
  --click-after-frames "5:${F1_XY}" \
  --key-after-frames "10:End:down;ArrowLeft:down;ArrowLeft:down;ArrowLeft:down" \
  --char-after-frames "14:88"
A_TEXT="$(caret_text "$LOG_A")"
A_POS="$(caret_pos "$LOG_A")"
[ "$A_TEXT" = "abcXdef" ] \
  || { tail -40 "$LOG_A" | sed 's/^/   /' >&2; fail "A: engine buffer should be 'abcXdef' after End+Left x3+'X'; got '$A_TEXT' -- InsertChar is not landing AT the caret"; }
[ "$A_POS" = "4" ] \
  || { tail -40 "$LOG_A" | sed 's/^/   /' >&2; fail "A: caret should be 4 after inserting 'X' at index 3; got $A_POS"; }
A_SEL_S="$(sel1_start "$LOG_A")"; A_SEL_E="$(sel1_end "$LOG_A")"
[ "$A_SEL_S" = "4" ] && [ "$A_SEL_E" = "4" ] \
  || { tail -40 "$LOG_A" | sed 's/^/   /' >&2; fail "A: onSelectionChange should report collapsed {4,4}; got {$A_SEL_S,$A_SEL_E}"; }
echo "   OK: 'abcXdef' caret=4 selection={4,4}"

echo "== B. synthetic: Home, Delete -> 'bcdef' =="
LOG_B="$WORK/arm-b.log"
run_win "$LOG_B" 40 \
  --click-after-frames "5:${F1_XY}" \
  --key-after-frames "10:Home:down;Delete:down"
B_TEXT="$(caret_text "$LOG_B")"
B_POS="$(caret_pos "$LOG_B")"
[ "$B_TEXT" = "bcdef" ] \
  || { tail -40 "$LOG_B" | sed 's/^/   /' >&2; fail "B: engine buffer should be 'bcdef' after Home+Delete; got '$B_TEXT' -- forward Delete is not removing the codepoint AFTER the caret"; }
[ "$B_POS" = "0" ] \
  || { tail -40 "$LOG_B" | sed 's/^/   /' >&2; fail "B: caret should stay 0 after Home+Delete; got $B_POS"; }
echo "   OK: 'bcdef' caret=0"

echo "== C. synthetic: type e-acute (U+00E9) + emoji (U+1F600), then Backspace =="
LOG_C="$WORK/arm-c.log"
run_win "$LOG_C" 60 \
  --click-after-frames "5:${F1_XY}" \
  --char-after-frames "10:U+00E9;U+1F600" \
  --key-after-frames "12:Backspace:down"
# Backspace is the LEGACY path (main.cpp's setKeyHandler), not dispatchKeyEvent
# -- it is only reachable via GLFW's real key callback in a window, which
# --key-after-frames drives through synthesiseKey -> dispatchKeyEvent ->
# fullKeyHandler_ AND the legacy keyHandler_ (both installed on the same
# GLFW callback; see GlfwSurface::dispatchKeyEvent). So the synthetic hook
# exercises Backspace correctly even though editing-Backspace is legacy.
C_POS_AFTER_EACUTE="$(sed -n 's/^rn-impeller: caret tag=[0-9-]* pos=\([0-9]*\) .*/\1/p' "$LOG_C" | sed -n '1p')"
[ "$C_POS_AFTER_EACUTE" = "8" ] \
  || { tail -50 "$LOG_C" | sed 's/^/   /' >&2; fail "C: after typing e-acute (2 UTF-8 bytes) onto 'abcdef' (6 bytes) caret should be at UTF-8 byte offset 8; got $C_POS_AFTER_EACUTE"; }
CHANGE_EACUTE="$(change1_nth "$LOG_C" 1)"
python3 -c '
import sys
got = sys.argv[1].encode("utf-8")
want = b"abcdef\xc3\xa9"
sys.exit(0 if got == want else 1)
' "$CHANGE_EACUTE" \
  || fail "C: onChangeText after typing e-acute should be the UTF-8 bytes 'abcdef' + C3 A9; got '$CHANGE_EACUTE'"
CHANGE_EMOJI="$(change1_nth "$LOG_C" 2)"
python3 -c '
import sys
got = sys.argv[1].encode("utf-8")
want = b"abcdef\xc3\xa9\xf0\x9f\x98\x80"
sys.exit(0 if got == want else 1)
' "$CHANGE_EMOJI" \
  || fail "C: onChangeText after typing the emoji should be 'abcdef'+e-acute's 2 bytes + the emoji's 4 UTF-8 bytes; got '$CHANGE_EMOJI' -- either the emoji codepoint was rejected (ASCII-only filter regression) or it was mangled"
C_SEL1_S="$(sed -n 's/^\[js\] ONSEL1 start=\([0-9-]*\) end=[0-9-]*$/\1/p' "$LOG_C" | sed -n '1p')"
[ "$C_SEL1_S" = "7" ] \
  || fail "C: selection after e-acute should be UTF-16 offset 7 (6 ASCII + 1 BMP unit); got $C_SEL1_S"
C_SEL2_S="$(sed -n 's/^\[js\] ONSEL1 start=\([0-9-]*\) end=[0-9-]*$/\1/p' "$LOG_C" | sed -n '2p')"
[ "$C_SEL2_S" = "9" ] \
  || fail "C: selection after the emoji should be UTF-16 offset 9 (7 + 2 surrogate units for the astral codepoint); got $C_SEL2_S -- selection is not being converted UTF-8 bytes -> UTF-16 units correctly"
# Backspace: removes the emoji WHOLE (4 UTF-8 bytes), not one byte.
C_TEXT_AFTER_BS="$(caret_text "$LOG_C")"
C_POS_AFTER_BS="$(caret_pos "$LOG_C")"
python3 -c '
import sys
got = sys.argv[1].encode("utf-8")
want = b"abcdef\xc3\xa9"
sys.exit(0 if got == want else 1)
' "$C_TEXT_AFTER_BS" \
  || fail "C: after Backspace the buffer should be exactly the UTF-8 bytes 'abcdef' + C3 A9 (emoji removed WHOLE); got '$C_TEXT_AFTER_BS' -- a single-byte-pop Backspace would leave 3 broken trailing bytes here"
[ "$C_POS_AFTER_BS" = "8" ] \
  || fail "C: caret after Backspace should return to UTF-8 byte offset 8; got $C_POS_AFTER_BS"
# Valid UTF-8: python must decode the exact bytes with no error.
printf '%s' "$C_TEXT_AFTER_BS" | python3 -c '
import sys
data = sys.stdin.buffer.read()
try:
    data.decode("utf-8", errors="strict")
except UnicodeDecodeError as e:
    print("INVALID_UTF8: %s" % e)
    sys.exit(1)
' || fail "C: buffer after Backspace is not valid UTF-8 -- Backspace popped a single byte off a multi-byte sequence"
echo "   OK: e-acute+emoji typed (UTF-16 selection 7 then 9), Backspace removes the emoji whole -> valid UTF-8 'abcdef\xc3\xa9'"

echo "== D. word move: Ctrl+ArrowLeft from end of 'abc def' -> caret 4 =="
LOG_D="$WORK/arm-d.log"
run_win "$LOG_D" 40 \
  --click-after-frames "5:${F2_XY}" \
  --key-after-frames "10:ArrowLeft:down:ctrl"
grep -q '^rn-impeller: textinput_focus=[1-9]' "$LOG_D" \
  || { grep 'textinput_focus' "$LOG_D" | sed 's/^/   /' >&2; fail "D: the click at F2_XY=$F2_XY focused no TextInput (textinput_focus=0) -- fixture layout and F2_XY disagree"; }
D_POS="$(caret_pos "$LOG_D")"
[ "$D_POS" = "4" ] \
  || { tail -40 "$LOG_D" | sed 's/^/   /' >&2; fail "D: Ctrl+ArrowLeft from end of 'abc def' (7 chars) should land the caret at 4 (start of 'def'); got $D_POS -- word-move is not skipping the word, or is skipping the wrong amount"; }
echo "   OK: word-left from end of 'abc def' -> caret 4"

echo "== E. pixel: caret painted LEFT of its end-of-text column after Left x3 =="
# Field 1 fresh-focuses to caret=END every run (SceneGraph::setTextInputFocus
# seeds tiCaret_ = value.size()). ONE run captures BOTH a --screenshot-first
# (frame 1, BEFORE the click at frame 5 -- no focus, no caret at all) and a
# timed --screenshot (after the click, caret at end, no moves): diffing these
# two gives the TRUE end-of-text caret column, since the caret is the ONLY
# thing that differs (the text 'abcdef' is identical, unedited, in both).
LOG_E1="$WORK/arm-e1.log"
run_win "$LOG_E1" 600 \
  --screenshot-first "$WORK/e1-nofocus.ppm" \
  --click-after-frames "5:${F1_XY}" \
  --screenshot "$WORK/e1-end.ppm" --screenshot-after 150
[ -s "$WORK/e1-nofocus.ppm" ] || fail "E: no screenshot-first produced"
[ -s "$WORK/e1-end.ppm" ] || fail "E: no timed screenshot produced (caret at end)"

LOG_E2="$WORK/arm-e2.log"
run_win "$LOG_E2" 600 \
  --screenshot-first "$WORK/e2-nofocus.ppm" \
  --click-after-frames "5:${F1_XY}" \
  --key-after-frames "10:ArrowLeft:down;ArrowLeft:down;ArrowLeft:down" \
  --screenshot "$WORK/e2-moved.ppm" --screenshot-after 150
[ -s "$WORK/e2-moved.ppm" ] || fail "E: no timed screenshot produced (caret after Left x3)"

# Field 1's interior band: x in [24,320) (left pad to right edge), y in the
# field's border-to-border range [21,55).
DIFF_END="$(python3 "$CI_TOOLS/caret-pixel-diff.py" \
  "$WORK/e1-nofocus.ppm" "$WORK/e1-end.ppm" 24 21 320 55)"
DIFF_MOVED="$(python3 "$CI_TOOLS/caret-pixel-diff.py" \
  "$WORK/e2-nofocus.ppm" "$WORK/e2-moved.ppm" 24 21 320 55)"
[ "$DIFF_END" != "NONE" ] \
  || fail "E: no pixel difference between the unfocused and focused-at-end frames -- no caret was painted AT ALL when focused (unrelated regression; the pixel oracle itself is broken)"
[ "$DIFF_MOVED" != "NONE" ] \
  || fail "E: no pixel difference between the unfocused and moved-caret frames -- the caret was NOT repainted after Left x3 (it is pinned to end-of-text regardless of the logical caret index -- item 2a's core defect)"
[ "$DIFF_MOVED" -lt "$DIFF_END" ] \
  || fail "E: caret column after Left x3 ($DIFF_MOVED) is not LEFT of the end-of-text caret column ($DIFF_END) -- the painted caret did not move left with the logical index"
echo "   OK: end-of-text caret column=$DIFF_END, after-Left-x3 column=$DIFF_MOVED (moved strictly left)"

echo "CARET_EDIT_GATE_PASS (caret move/word/line/delete/edit-at-caret + UTF-8 typing + painted position)"
