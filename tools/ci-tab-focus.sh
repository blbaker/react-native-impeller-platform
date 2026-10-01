#!/usr/bin/env bash
# desktop-input-gap item 11 GATE: Tab / Shift+Tab keyboard focus traversal.
#
# Tab moves focus to the next focusable element in tree order, Shift+Tab to
# the previous, wrapping. Focusable = an editable TextInput whose focusable
# prop is not false (tabIndex -1 -> false) or a <View focusable>. Tabbing
# into a field selects all its text; a focused View gets onFocus, key events
# and a focus ring. Ctrl+Tab does not navigate.
#
# Fixture tab order: A B VIEW E (C editable=false and D tabIndex=-1 skipped).
#
# Arms:
#   a  click A (past the end), Tab -> BLUR A, FOCUS B, SEL B {0,3}
#   b  Tab again -> FOCUS VIEW; a key 'x' then reaches VIEWKEY x
#   c  Tab again -> skips C and D, lands on E
#   d  Tab from E wraps to A; Shift+Tab from A wraps to E
#   e  Ctrl+Tab does not move focus
#   f  Tab into B then type Z -> CHANGE B text=Z (selection replaced)
#   g  REAL XTest: Tab, Tab, Shift+Tab -> B, VIEW, B
#   h  PIXEL: focus ring colour around VIEW only while it is focused
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/item11-tab-focus"
APP_NAME="Item11TabFocus"

fail() { echo "TAB_FOCUS_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/TabFocusApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="tabfocusapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="Item11TabFocus"; a.displayName="Tab Focus Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the item 11 tab-focus fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/tab-focus.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/tab-focus.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"





WIN_W=400
WIN_H=300
A_XY="300,25"

assert_scene_mounted() {  # $1 = log path
  local nodes
  nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$1" | tail -1)"
  [ -n "$nodes" ] || { tail -30 "$1" | sed 's/^/   /' >&2; fail "no 'scene_nodes=' line -- the app did not reach startSurface"; }
  [ "$nodes" -gt 0 ] \
    || fail "scene_nodes=$nodes -- the fixture mounted NOTHING (mismatched --app-name is the classic cause)"
}
dump() { grep -E '\[js\]|focus_move|selection tag' "$1" | sed 's/^/   /' >&2; }
has()  { grep -qE "^\[js\] $2\$" "$1"; }
# Names that got FOCUS, in order, space-separated.
focus_seq() { sed -n 's/^\[js\] FOCUS \(.*\)$/\1/p' "$1" | tr '\n' ' ' | sed 's/ $//'; }

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

echo "== a. click A, Tab -> B with all text selected =="
run_win "$WORK/a.log" 50 --click-after-frames "5:$A_XY" --key-after-frames "10:Tab:down"
[ "$(focus_seq "$WORK/a.log")" = "A B" ] && has "$WORK/a.log" 'BLUR A' \
  || { dump "$WORK/a.log"; fail "a: clicking A then Tab should focus A then B and blur A; got focus '$(focus_seq "$WORK/a.log")' -- Tab does not move focus forward"; }
has "$WORK/a.log" 'SEL B start=0 end=3' \
  || { dump "$WORK/a.log"; fail "a: tabbing into B should select all of 'bbb' {0,3} -- no select-all on Tab focus"; }
echo "   OK: A -> B, BLUR A, B selected {0,3}"

echo "== b. Tab to the focusable View; keys reach it =="
run_win "$WORK/b.log" 50 --click-after-frames "5:$A_XY" --key-after-frames "10:Tab:down;Tab:down;x:down"
[ "$(focus_seq "$WORK/b.log")" = "A B VIEW" ] \
  || { dump "$WORK/b.log"; fail "b: A, Tab, Tab should focus A B VIEW; got '$(focus_seq "$WORK/b.log")' -- Tab does not move focus forward, or the View's onFocus never reached JS"; }
has "$WORK/b.log" 'VIEWKEY x' \
  || { dump "$WORK/b.log"; fail "b: a key pressed while the View is focused should reach its onKeyDown -- key events are not routed to the focused View"; }
echo "   OK: VIEW focused, VIEWKEY x"

echo "== c. Tab skips editable=false and tabIndex=-1 =="
run_win "$WORK/c.log" 50 --click-after-frames "5:$A_XY" --key-after-frames "10:Tab:down;Tab:down;Tab:down"
[ "$(focus_seq "$WORK/c.log")" = "A B VIEW E" ] \
  || { dump "$WORK/c.log"; fail "c: three Tabs from A should land on E, skipping C (editable=false) and D (tabIndex -1); got '$(focus_seq "$WORK/c.log")' -- a non-focusable field is in the Tab order"; }
echo "   OK: A B VIEW E"

echo "== d. wrap-around both ways =="
run_win "$WORK/d.log" 60 --click-after-frames "5:$A_XY" \
  --key-after-frames "10:Tab:down;Tab:down;Tab:down;Tab:down;Tab:down:shift"
[ "$(focus_seq "$WORK/d.log")" = "A B VIEW E A E" ] \
  || { dump "$WORK/d.log"; fail "d: Tab x4 then Shift+Tab from A should give A B VIEW E A E; got '$(focus_seq "$WORK/d.log")' -- focus does not wrap, or Shift+Tab does not go backwards"; }
echo "   OK: A B VIEW E A E"

echo "== e. Ctrl+Tab does not navigate =="
run_win "$WORK/e.log" 50 --click-after-frames "5:$A_XY" --key-after-frames "10:Tab:down:ctrl"
[ "$(focus_seq "$WORK/e.log")" = "A" ] \
  || { dump "$WORK/e.log"; fail "e: Ctrl+Tab should not move focus; got '$(focus_seq "$WORK/e.log")' -- Ctrl+Tab navigates"; }
echo "   OK: focus stays on A"

echo "== f. typing after Tab replaces the selected text =="
run_win "$WORK/f.log" 50 --click-after-frames "5:$A_XY" --key-after-frames "10:Tab:down" --char-after-frames "14:90"
has "$WORK/f.log" 'CHANGE B text=Z' \
  || { dump "$WORK/f.log"; fail "f: Tab into B then typing Z should replace 'bbb' with 'Z' -- no select-all on Tab focus"; }
echo "   OK: B = 'Z'"

echo "== h. PIXEL: focus ring only while the View is focused =="
run_win "$WORK/h1.log" 600 --click-after-frames "5:$A_XY" --key-after-frames "10:Tab:down;Tab:down" \
  --screenshot "$WORK/h-focused.ppm" --screenshot-after 300
run_win "$WORK/h2.log" 600 --click-after-frames "5:$A_XY" --key-after-frames "10:Tab:down;Tab:down;Tab:down" \
  --screenshot "$WORK/h-unfocused.ppm" --screenshot-after 300
RING="$(python3 - "$WORK/h-focused.ppm" "$WORK/h-unfocused.ppm" <<'PY'
import sys
def rd(p):
    d = open(p, "rb").read(); parts = d.split(b"\n", 3)
    w, h = (int(v) for v in parts[1].split()); return w, h, parts[3]
def ring(path):
    w, h, b = rd(path); n = 0
    # The VIEW frame is x 20..320, y 90..120; the ring is drawn 2 px outside.
    for y in list(range(86, 90)) + list(range(120, 124)):
        for x in range(30, 310):
            i = (y * w + x) * 3
            r, g, bb = b[i], b[i + 1], b[i + 2]
            if bb > 180 and r < 80 and 60 < g < 160:
                n += 1
    return n
print("%d %d" % (ring(sys.argv[1]), ring(sys.argv[2])))
PY
)"
set -- $RING
echo "   ring pixels: focused=$1 unfocused=$2"
[ "$1" -gt 200 ] || fail "h: no focus-ring pixels around the focused View ($RING) -- the focus ring is not painted"
[ "$2" = "0" ] || fail "h: focus-ring pixels remain after focus moved on ($RING) -- the focus ring is not cleared on blur"
echo "   OK: ring drawn when focused, gone when not"

echo "== g. REAL XTest: Tab, Tab, Shift+Tab =="
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
  echo "TAB_FOCUS_GATE_SKIP_G: no DISPLAY / python-xlib -- the REAL-key arm did not run."
else
  REAL_LOG="$WORK/real.log"
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name "$APP_NAME" \
      --width "$WIN_W" --height "$WIN_H" --idle-skip --idle-run-sec 10 \
      > "$REAL_LOG" 2>&1 &
  PID=$!
  sleep 4
  "$XPY" "$XCLICK" "React Native (Impeller)" 300 25 > "$WORK/xc.log" 2>&1; R1=$?
  "$XPY" "$XKEY" "React Native (Impeller)" Tab Tab Tab+shift > "$WORK/xk.log" 2>&1; R2=$?
  wait "$PID"; APPRC=$?
  set -e
  [ "$R1$R2" = "00" ] || { cat "$WORK/xc.log" "$WORK/xk.log" | sed 's/^/   /' >&2; fail "g: XTest driver failed ($R1$R2)"; }
  [ "$APPRC" -eq 0 ] || { tail -30 "$REAL_LOG" | sed 's/^/   /' >&2; fail "g: windowed app exited $APPRC"; }
  assert_scene_mounted "$REAL_LOG"
  [ "$(focus_seq "$REAL_LOG")" = "A B VIEW B" ] \
    || { dump "$REAL_LOG"; fail "g: REAL click A, Tab, Tab, Shift+Tab should focus A B VIEW B; got '$(focus_seq "$REAL_LOG")' -- Tab does not move focus forward, or Shift+Tab does not go backwards"; }
  echo "   OK: REAL A B VIEW B"
fi

echo "TAB_FOCUS_GATE_PASS (Tab/Shift+Tab traversal, wrap, skip editable=false + tabIndex -1, select-all on focus, View focus + keys + ring, Ctrl+Tab ignored)"
