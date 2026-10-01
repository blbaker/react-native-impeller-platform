#!/usr/bin/env bash
# parity item 7 GATE: view commands reach the engine.
#
# RN routes ref.scrollTo(), ref.scrollToEnd(), TextInput ref.focus()/.blur()/
# .setSelection() and controlled `value`/`selection` updates through
# UIManager view commands. SchedulerDelegate::schedulerDidDispatchCommand was
# an empty stub, so all of them were silently dropped.
#
# Arms (each presses one fixture button, then reads native + JS lines):
#   a  scrollTo({y:40})     -> scroll_command y=40.0 and JS ONSCROLL y=40
#   b  scrollToEnd()        -> y=300.0 (content 400 - viewport 100)
#   c  b.focus()            -> FOCUS B; a following char lands in B
#   d  focus then blur      -> BLUR B
#   e  focus, setSelection(1,4) -> engine selection anchor=1 caret=4, SEL B {1,4}
#   f  controlled value change on an unfocused field -> displayed text 'hello'
#   g  controlled value, focused field: selection={2,4} prop -> SEL C {2,4}
#   h  pixel: after scrollTo({y:40}) the first visible row is row 1's colour
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item7-commands"
APP_NAME="Item7Commands"

fail() { echo "COMMANDS_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/CommandsApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="commandsapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item7Commands"; a.displayName="Commands Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 7 commands fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/commands.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/commands.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"






WIN_W=400
WIN_H=300
SCROLL40="45,125"; TOEND="145,125"; FOCUSB="245,125"; BLURB="345,125"
SELECTB="45,165"; SETTEXT="145,165"; CTLSEL="245,165"
C_XY="300,280"

assert_scene_mounted() {  # $1 = log path
  local nodes
  nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$1" | tail -1)"
  [ -n "$nodes" ] || { tail -30 "$1" | sed 's/^/   /' >&2; fail "no 'scene_nodes=' line -- the app did not reach startSurface"; }
  [ "$nodes" -gt 0 ] \
    || fail "scene_nodes=$nodes -- the fixture mounted NOTHING (mismatched --app-name is the classic cause)"
}
dump() { grep -E '\[js\]|rn-impeller: (command|scroll_command|caret|selection|settext)' "$1" | sed 's/^/   /' >&2; }
has()  { grep -qE "$2" "$1"; }
clicks() {  # build a --mouse-after-frames spec: one down/up pair per point
  local spec="" p
  for p in "$@"; do spec="$spec;down@$p;up@$p"; done
  echo "${spec#;}"
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

echo "== a. scrollTo({y:40}) =="
run_win "$WORK/a.log" 60 --mouse-after-frames "8:$(clicks $SCROLL40)"
has "$WORK/a.log" '^rn-impeller: scroll_command tag=[0-9]+ x=0.0 y=40.0$' \
  && has "$WORK/a.log" '^\[js\] ONSCROLL y=40$' \
  || { dump "$WORK/a.log"; fail "a: scrollTo({y:40}) should move the ScrollView to y=40 and fire onScroll y=40 -- view commands are dropped"; }
echo "   OK: y=40, onScroll y=40"

echo "== b. scrollToEnd() =="
run_win "$WORK/b.log" 60 --mouse-after-frames "8:$(clicks $TOEND)"
has "$WORK/b.log" '^rn-impeller: scroll_command tag=[0-9]+ x=0.0 y=300.0$' \
  || { dump "$WORK/b.log"; fail "b: scrollToEnd() should scroll to y=300 (content 400 - viewport 100) -- scrollToEnd is not handled"; }
echo "   OK: y=300"

echo "== c. focus() then type =="
run_win "$WORK/c.log" 60 --mouse-after-frames "8:$(clicks $FOCUSB)" --char-after-frames "20:90"
has "$WORK/c.log" '^\[js\] FOCUS B$' \
  || { dump "$WORK/c.log"; fail "c: ref.focus() should focus field B -- the focus command is dropped"; }
has "$WORK/c.log" '^rn-impeller: caret tag=[0-9]+ pos=7 text=bbbbbbZ$' \
  || { dump "$WORK/c.log"; fail "c: a char typed after ref.focus() should land in B at the end ('bbbbbbZ') -- the focus command is dropped"; }
echo "   OK: FOCUS B, typed into B"

echo "== d. focus() then blur() =="
run_win "$WORK/d.log" 60 --mouse-after-frames "8:$(clicks $FOCUSB $BLURB)"
has "$WORK/d.log" '^\[js\] FOCUS B$' && has "$WORK/d.log" '^\[js\] BLUR B$' \
  || { dump "$WORK/d.log"; fail "d: ref.blur() after ref.focus() should fire onBlur on B -- the blur command is dropped"; }
echo "   OK: FOCUS B, BLUR B"

echo "== e. focus() then setSelection(1, 4) =="
run_win "$WORK/e.log" 60 --mouse-after-frames "8:$(clicks $FOCUSB $SELECTB)"
has "$WORK/e.log" '^rn-impeller: selection tag=[0-9]+ anchor=1 caret=4 command=1$' \
  && has "$WORK/e.log" '^\[js\] SEL B start=1 end=4$' \
  || { dump "$WORK/e.log"; fail "e: ref.setSelection(1,4) should select {1,4} in B -- setTextAndSelection is not applied"; }
echo "   OK: {1,4}"

echo "== f. controlled value on an unfocused field =="
run_win "$WORK/f.log" 60 --mouse-after-frames "8:$(clicks $SETTEXT)"
has "$WORK/f.log" '^rn-impeller: settext_unfocused tag=[0-9]+ text=hello$' \
  || { dump "$WORK/f.log"; fail "f: setting C's controlled value to 'hello' should update the field -- setTextAndSelection text is not applied"; }
echo "   OK: C shows 'hello'"

echo "== g. controlled selection prop on the focused field =="
# Press ctlSel (its selection update is delayed 400 ms), then click C so C is
# focused when the update arrives; a click on the button itself blurs C.
# Held for 3 s of wall time (frames=0 + --idle-skip --idle-run-sec): a frame
# budget alone could end the run before the delayed update lands.
run_win "$WORK/g.log" 0 --mouse-after-frames "8:$(clicks $CTLSEL $C_XY)" \
  --idle-skip --idle-run-sec 3
has "$WORK/g.log" '^\[js\] SEL C start=2 end=4$' \
  && has "$WORK/g.log" '^rn-impeller: selection tag=[0-9]+ anchor=2 caret=4 command=1$' \
  || { dump "$WORK/g.log"; fail "g: the selection={2,4} prop on focused C should select {2,4} -- setTextAndSelection is not applied"; }
echo "   OK: {2,4}"

echo "== h. PIXEL: rows moved after scrollTo({y:40}) =="
run_win "$WORK/h0.log" 600 --screenshot "$WORK/h0.ppm" --screenshot-after 300
run_win "$WORK/h1.log" 600 --mouse-after-frames "8:$(clicks $SCROLL40)" \
  --screenshot "$WORK/h1.ppm" --screenshot-after 300
PX="$(python3 - "$WORK/h0.ppm" "$WORK/h1.ppm" <<'PY'
import sys
def px(p, x, y):
    d = open(p, "rb").read(); parts = d.split(b"\n", 3)
    w = int(parts[1].split()[0]); b = parts[3]; i = (y * w + x) * 3
    return tuple(b[i:i + 3])
print("%s %s" % (px(sys.argv[1], 150, 20), px(sys.argv[2], 150, 20)))
PY
)"
echo "   pixel (150,20) before / after: $PX"
python3 -c '
import sys, ast
s = sys.argv[1]
a, b = s.split(") (")
a = ast.literal_eval(a + ")"); b = ast.literal_eval("(" + b)
# row 0 is #442222 (red-dominant), row 1 is #224422 (green-dominant)
sys.exit(0 if a[0] > a[1] and b[1] > b[0] else 1)
' "$PX" || fail "h: after scrollTo({y:40}) the top row should be row 1 (green) instead of row 0 (red); got $PX -- the scroll command did not repaint"
echo "   OK: top row changed red -> green"

echo "COMMANDS_GATE_PASS (scrollTo, scrollToEnd, focus, blur, setSelection, controlled value + selection, repaint)"
