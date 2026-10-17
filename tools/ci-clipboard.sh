#!/usr/bin/env bash
# desktop-input-gap item 5 GATE: system Clipboard module + Cut/Copy/Paste.
#
# Fixture: fixtures/item5-clipboard (field 1 'abcdef' y 20..56, field 2 empty
# y 76..112, "setget" button y 130..160 that round-trips Clipboard.setString/
# getString through JS, "setnewline" button y 170..200 that sets a multi-line
# string on the clipboard). Focus clicks land at x=300 -- PAST the end of
# every field's text -- so click-to-caret always leaves the caret at the end.
#
# Arms:
#   a  JS round trip: press "setget" -> '[js] GETSTRING=hello é'
#   b  copy/paste across fields: field1 Ctrl+A/Ctrl+C, focus field2, Ctrl+V
#      -> field2 'abcdef'
#   c  cut: field1 Shift+Left x3, Ctrl+X -> field1 'abc'; paste into field2
#      -> 'def'
#   d  paste replaces a selection: clipboard 'XY' (typed+copied from field2),
#      select {3,6} in field1, Ctrl+V -> 'abcXY'
#   e  newline flattening: clipboard 'a\nb\r\nc' (via "setnewline"), paste
#      into the empty field -> 'a b c'
#   f  copy with an empty selection does not touch the clipboard; a later
#      paste still yields the earlier copied content
#   g  REAL system clipboard round trip while the window is ALIVE: real
#      XTest Ctrl+A/Ctrl+C, read CLIPBOARD from OUTSIDE the process; and the
#      reverse direction, an external owner sets CLIPBOARD and a real
#      Ctrl+V pastes it
#
# ⛔ ONE key-after-frames SEQUENCE AND ONE mouse-after-frames SEQUENCE PER RUN.
# Each flag installs exactly one contiguous, one-event-per-frame hook starting
# at a fixed frame; it cannot be paused and resumed. Arms that need a mouse
# click to land BETWEEN two keyboard actions therefore pad the key sequence
# with harmless filler presses (a bare "Shift" down, which dispatchKeyEvent's
# caret-routing branch does not recognise and so never touches the buffer or
# the selection) so the REAL key the arm cares about lands on a frame AFTER
# the mouse sequence's last event. Hooks that share one frame number execute
# in the loop's fixed per-iteration order (click, scroll, hover, key, char,
# mouse -- see RunWindowed in engine/host/main.cpp), i.e. a key event on frame
# N always fires BEFORE a mouse event on that same frame N; that is why every
# filler frame below is chosen to OVERLAP the mouse sequence rather than
# follow it, and the real post-click key is scheduled on the first frame
# strictly after the mouse sequence ends.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item5-clipboard"
APP_NAME="Item5Clipboard"

fail() { echo "CLIPBOARD_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/ClipboardApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="clipboardapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item5Clipboard"; a.displayName="Clipboard Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 5 clipboard fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/react-native-impeller-platform/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/clipboard.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/clipboard.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"

WIN_W=400
WIN_H=300
F1_Y=38
F2_Y=94
SETGET_XY="110,145"
SETNEWLINE_XY="110,185"

# The platform's primary shortcut modifier. FabricHost::dispatchKeyEvent maps
# Select-all/Copy/Cut/Paste to Cmd (meta) under __APPLE__ and to Ctrl
# everywhere else, so a chord hard-coded to ctrl is a no-op on darwin and
# arms b-f could never pass there. RNI_CLIP_PMOD overrides the pick so the
# mutation check can drive the WRONG chord and prove the gate goes red.
case "$(uname -s)" in
  Darwin) PMOD_AUTO=meta ;;
  *)      PMOD_AUTO=ctrl ;;
esac
PMOD="${RNI_CLIP_PMOD:-$PMOD_AUTO}"
case "$PMOD" in ctrl|meta) ;; *) fail "RNI_CLIP_PMOD must be ctrl or meta, got '$PMOD'" ;; esac
echo "   primary modifier: $PMOD (uname $(uname -s), auto=$PMOD_AUTO)"
SA="a:down:$PMOD"; CP="c:down:$PMOD"; CT="x:down:$PMOD"; PS="v:down:$PMOD"

assert_scene_mounted() {  # $1 = log path
  local nodes
  nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$1" | tail -1)"
  [ -n "$nodes" ] || { tail -30 "$1" | sed 's/^/   /' >&2; fail "no 'scene_nodes=' line -- the app did not reach startSurface"; }
  [ "$nodes" -gt 0 ] \
    || fail "scene_nodes=$nodes -- the fixture mounted NOTHING (mismatched --app-name is the classic cause)"
}
onchange_last() { sed -n "s/^\[js\] ONCHANGE$2 text=\(.*\)\$/\1/p" "$1" | tail -1; }
clip_ops()      { grep -c "^rn-impeller: clipboard op=$2" "$1" || true; }
# POSITIVE CONTROL: the exact clipboard op counts the arm's chords must have
# produced. A text assertion alone can be satisfied without the shortcut
# path ever firing; a count of 0 here means the $PMOD chord never reached
# Copy/Cut/Paste on this platform. $1=log $2=arm $3="op=N op=N ...".
assert_ops() {
  local log="$1" arm="$2" pair op want got
  for pair in $3; do
    op="${pair%%=*}"; want="${pair#*=}"
    got="$(clip_ops "$log" "$op ")"
    [ "$got" = "$want" ] || { dump "$log"; fail "$arm: expected exactly $want 'clipboard op=$op' line(s) from the $PMOD chord; got $got -- the $PMOD+key shortcut did not reach the clipboard action on $(uname -s)"; }
  done
}
dump() { grep -E 'ONCHANGE|ONSEL|GETSTRING|clipboard op=|textinput_focus' "$1" | sed 's/^/   /' >&2; }

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

echo "== a. JS round trip: setget button -> GETSTRING=hello é =="
run_win "$WORK/a.log" 50 --click-after-frames "5:$SETGET_XY"
grep -qF '[js] GETSTRING=hello é' "$WORK/a.log" \
  || { dump "$WORK/a.log"; fail "a: expected '[js] GETSTRING=hello é' -- the JS Clipboard.getString() round trip did not resolve the value setString just wrote"; }
echo "   OK: GETSTRING=hello é"

echo "== b. copy field1, focus field2, paste -> 'abcdef' =="
run_win "$WORK/b.log" 50 --click-after-frames "5:300,$F1_Y" \
  --key-after-frames "15:$SA;$CP;Shift:down;Shift:down;$PS" \
  --mouse-after-frames "17:down@300,$F2_Y;up@300,$F2_Y"
assert_ops "$WORK/b.log" b "copy=1 cut=0 paste=1"
echo "   OK: positive control -- $PMOD chord produced exactly 1 op=copy, 1 op=paste"
B_RESULT="$(onchange_last "$WORK/b.log" 2)"
[ "$B_RESULT" = "abcdef" ] \
  || { dump "$WORK/b.log"; fail "b: pasting into field2 after copying field1's full selection should give 'abcdef'; got '$B_RESULT' -- Copy/Paste are not round-tripping through the system clipboard"; }
echo "   OK: field2 = 'abcdef'"

echo "== c. cut field1 'def', paste into field2 -> field1 'abc' field2 'def' =="
run_win "$WORK/c.log" 50 --click-after-frames "5:300,$F1_Y" \
  --key-after-frames "15:ArrowLeft:down:shift;ArrowLeft:down:shift;ArrowLeft:down:shift;$CT;Shift:down;Shift:down;$PS" \
  --mouse-after-frames "19:down@300,$F2_Y;up@300,$F2_Y"
assert_ops "$WORK/c.log" c "cut=1 copy=0 paste=1"
C_F1="$(onchange_last "$WORK/c.log" 1)"
C_F2="$(onchange_last "$WORK/c.log" 2)"
[ "$C_F1" = "abc" ] \
  || { dump "$WORK/c.log"; fail "c: cutting 'def' from field1 should leave 'abc'; got '$C_F1' -- Cut did not erase the selection"; }
[ "$C_F2" = "def" ] \
  || { dump "$WORK/c.log"; fail "c: pasting the cut text into field2 should give 'def'; got '$C_F2' -- Cut did not reach the system clipboard, or Paste did not read it"; }
echo "   OK: field1='abc' field2='def'"

echo "== d. paste replaces a selection: clipboard 'XY', select {3,6} -> 'abcXY' =="
run_win "$WORK/d.log" 50 --click-after-frames "5:200,$F2_Y" \
  --char-after-frames "10:88;89" \
  --key-after-frames "15:$SA;$CP;Shift:down;Shift:down;ArrowLeft:down:shift;ArrowLeft:down:shift;ArrowLeft:down:shift;$PS" \
  --mouse-after-frames "17:down@300,$F1_Y;up@300,$F1_Y"
assert_ops "$WORK/d.log" d "copy=1 cut=0 paste=1"
D_CLIP_SRC="$(onchange_last "$WORK/d.log" 2)"
[ "$D_CLIP_SRC" = "XY" ] \
  || { dump "$WORK/d.log"; fail "d: typing X,Y into field2 should give 'XY' before it is copied; got '$D_CLIP_SRC'"; }
D_RESULT="$(onchange_last "$WORK/d.log" 1)"
[ "$D_RESULT" = "abcXY" ] \
  || { dump "$WORK/d.log"; fail "d: pasting 'XY' over the selection {3,6} in field1 should give 'abcXY'; got '$D_RESULT' -- Paste does not replace the selection (it may be inserting at the caret instead)"; }
echo "   OK: field1 = 'abcXY'"

echo "== e. newline flattening: 'a\\nb\\r\\nc' pastes as 'a b c' =="
run_win "$WORK/e.log" 50 --click-after-frames "5:$SETNEWLINE_XY" \
  --mouse-after-frames "10:down@300,$F2_Y;up@300,$F2_Y" \
  --key-after-frames "10:Shift:down;Shift:down;$PS"
assert_ops "$WORK/e.log" e "copy=0 cut=0 paste=1"
E_RESULT="$(onchange_last "$WORK/e.log" 2)"
[ "$E_RESULT" = "a b c" ] \
  || { dump "$WORK/e.log"; fail "e: pasting 'a\\nb\\r\\nc' into a single-line field should flatten every CR/LF run to one space, giving 'a b c'; got '$E_RESULT' -- newline flattening on paste is missing or wrong"; }
echo "   OK: field2 = 'a b c'"

echo "== f. copy with an empty selection does not touch the clipboard =="
run_win "$WORK/f.log" 50 --click-after-frames "5:300,$F1_Y" \
  --key-after-frames "15:$SA;$CP;ArrowLeft:down;$CP;Shift:down;Shift:down;$PS" \
  --mouse-after-frames "19:down@300,$F2_Y;up@300,$F2_Y"
F_COPY_COUNT="$(clip_ops "$WORK/f.log" copy)"
[ "$F_COPY_COUNT" = "1" ] \
  || { dump "$WORK/f.log"; fail "f: expected exactly 1 'clipboard op=copy' line (the first Ctrl+C only); got $F_COPY_COUNT -- a Ctrl+C with no selection wrote to the clipboard anyway"; }
assert_ops "$WORK/f.log" f "cut=0 paste=1"
F_RESULT="$(onchange_last "$WORK/f.log" 2)"
[ "$F_RESULT" = "abcdef" ] \
  || { dump "$WORK/f.log"; fail "f: pasting after a no-op Copy should still give the FIRST copy's content 'abcdef'; got '$F_RESULT' -- the clipboard was corrupted or cleared by the empty-selection Copy"; }
echo "   OK: second Ctrl+C was a no-op, paste still gives 'abcdef'"

echo "== g. REAL system clipboard round trip (window ALIVE) =="
XKEY="$CI_TOOLS/xkey.py"
XCLICK="$CI_TOOLS/xclick.py"
XCLIPREAD="$CI_TOOLS/xclip-read.py"
XCLIPWRITE="$CI_TOOLS/xclip-write.py"
XPY=""
for cand in "${RNI_PYTHON:-}" python3 "$HOME/.cache/rni/xtest-venv/bin/python"; do
  [ -n "$cand" ] || continue
  command -v "$cand" > /dev/null 2>&1 || [ -x "$cand" ] || continue
  "$cand" -c 'from Xlib import display; from Xlib.ext import xtest; display.Display()' \
      > /dev/null 2>&1 || continue
  XPY="$cand"; break
done
if [ -z "$XPY" ]; then
  echo "CLIPBOARD_GATE_SKIP_G: no DISPLAY / python-xlib -- the REAL-clipboard arm did not run."
else
  REAL_LOG="$WORK/real.log"
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name "$APP_NAME" \
      --width "$WIN_W" --height "$WIN_H" --idle-skip --idle-run-sec 16 \
      > "$REAL_LOG" 2>&1 &
  PID=$!
  sleep 4
  "$XPY" "$XCLICK" "React Native (Impeller)" 300 "$F1_Y" > "$WORK/xg1.log" 2>&1; R1=$?
  "$XPY" "$XKEY" "React Native (Impeller)" a+ctrl c+ctrl > "$WORK/xg2.log" 2>&1; R2=$?
  sleep 0.3
  if [ "$R1$R2" != "00" ]; then
    kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true
    cat "$WORK"/xg1.log "$WORK"/xg2.log | sed 's/^/   /' >&2
    fail "g: XTest driver failed ($R1$R2)"
  fi
  # read from OUTSIDE the process -- a different X client, its own window.
  G_CLIP="$("$XPY" "$XCLIPREAD" 5 2>"$WORK/xg3.err")"; R3=$?
  if [ "$R3" -ne 0 ]; then
    kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true
    cat "$WORK/xg3.err" | sed 's/^/   /' >&2
    fail "g: reading CLIPBOARD from outside the process failed (rc=$R3) -- see stderr above"
  fi
  [ "$G_CLIP" = "abcdef" ] \
    || { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; \
         fail "g: CLIPBOARD read from OUTSIDE the process after a REAL Ctrl+A/Ctrl+C should be 'abcdef'; got '$G_CLIP' -- the real-key path is not reaching the GLFW system clipboard"; }
  echo "   OK: external read of CLIPBOARD after real Ctrl+A/Ctrl+C -> 'abcdef'"

  # other direction: an EXTERNAL owner sets CLIPBOARD, a real Ctrl+V pastes it.
  "$XPY" "$XCLIPWRITE" "outside-owner-xyz" 6 > "$WORK/xg4.log" 2>&1 &
  WPID=$!
  OWNER_WAIT=0
  while [ "$OWNER_WAIT" -lt 30 ] && ! grep -q XCLIPWRITE_OWNER "$WORK/xg4.log" 2>/dev/null; do
    sleep 0.1; OWNER_WAIT=$((OWNER_WAIT + 1))
  done
  grep -q XCLIPWRITE_OWNER "$WORK/xg4.log" 2>/dev/null \
    || { kill "$PID" "$WPID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; \
         fail "g: the external clipboard-owner helper never acquired CLIPBOARD ownership"; }
  "$XPY" "$XCLICK" "React Native (Impeller)" 300 "$F2_Y" > "$WORK/xg5.log" 2>&1; R5=$?
  "$XPY" "$XKEY" "React Native (Impeller)" v+ctrl > "$WORK/xg6.log" 2>&1; R6=$?
  sleep 0.5
  wait "$WPID" 2>/dev/null || true
  wait "$PID"; APPRC=$?
  set -e
  if [ "$R5$R6" != "00" ]; then
    cat "$WORK"/xg5.log "$WORK"/xg6.log | sed 's/^/   /' >&2
    fail "g: XTest driver failed on the reverse-direction arm ($R5$R6)"
  fi
  [ "$APPRC" -eq 0 ] || { tail -30 "$REAL_LOG" | sed 's/^/   /' >&2; fail "g: windowed app exited $APPRC"; }
  assert_scene_mounted "$REAL_LOG"
  G2_RESULT="$(onchange_last "$REAL_LOG" 2)"
  [ "$G2_RESULT" = "outside-owner-xyz" ] \
    || { dump "$REAL_LOG"; fail "g: a real Ctrl+V after an EXTERNAL process set CLIPBOARD should paste 'outside-owner-xyz' into field2; got '$G2_RESULT' -- the engine is not reading an externally-owned CLIPBOARD"; }
  echo "   OK: real Ctrl+V pasted an externally-set CLIPBOARD value"
fi

echo "CLIPBOARD_GATE_PASS (JS round trip, copy/cut/paste across fields, selection replace, newline flattening, empty-selection no-op, real X11 round trip both directions)"
