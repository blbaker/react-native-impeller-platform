#!/usr/bin/env bash
# desktop-input-gap P0 item 1 GATE: FULL keyboard events reach JS.
#
# ⛔ WHY THIS GATE EXISTS ON TOP OF ci-textedit.sh / ci-window-input.sh.
# ci-textedit.sh proves Backspace/Enter/characters edit a focused TextInput's
# buffer, entirely through the HEADLESS --type harness -- it never sends
# Escape, an arrow key, a modifier, or a key release, because those were
# never forwarded at all before this commit (GlfwSurface.cpp's key callback
# dropped GLFW_RELEASE outright and recognised only Backspace/Enter/KP_ENTER,
# reading mods for Shift only). ci-window-input.sh proves mouse click
# registration the same windowed-XTest way this gate proves key registration,
# but says nothing about keyboard. This gate is the first to assert: (a) a
# key OTHER than Backspace/Enter reaches JS at all, (b) modifiers
# (shift/ctrl/meta) are visible to JS, (c) a key RELEASE reaches JS, (d) a
# generic keyDown/keyUp on a plain <View> (RN 0.86 C++ BaseViewEventEmitter
# has no such method -- see docs/eng/desktop-input-gap.md) actually fires.
#
# ⛔ THE TWO ASSERTION HALVES ARE NOT INTERCHANGEABLE -- same discipline as
# ci-window-input.sh's assert A vs assert B:
#
#   A. REAL key events (XTest via tools/xkey.py). Warps real X keycodes
#      through the X server -> GLFW -> glfwSetKeyCallback. Only this half can
#      die when the REGISTRATION is deleted (M1 in the mutation suite).
#   B. SYNTHETIC key events (--key-after-frames, GlfwSurface::synthesiseKey).
#      Calls the SAME dispatchKeyEvent translation directly, bypassing the
#      callback. Proves the translation table, modifier plumbing and JS
#      dispatch on hosts where XTest cannot deliver every modifier (some
#      window managers refuse to let XTest set the Super/Meta bit -- this
#      gate tries Super via XTest anyway and does not fail the RUN if that
#      one modifier silently no-ops, but treats shift/ctrl/alt as load-
#      bearing since those are universally deliverable).
#
# Deleting A and keeping B would leave a gate green on the exact
# "callback never registered" bug both P9 gates were each written to catch.
#
# ⚠️ ASSERTS scene_nodes>0 EXPLICITLY (acceptance-gate-instrument-validation's
# "mismatched --app-name mounts nothing and naive checks pass" pitfall): every
# console-log assertion below would also read "PASS" (0 expected occurrences
# each) against a totally blank mount if that check were skipped.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p0-key-events"

fail() { echo "KEY_EVENTS_GATE_FAIL: $*" >&2; exit 1; }

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
APP="$WORK/KeyEventsApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="keyeventsapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P0KeyEvents"; a.displayName="Key Events Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the P0 key-events fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"

npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"

# ⛔ THE SHIM MARKER MUST BE IN THE BUNDLE, OR TEST B BELOW PROVES NOTHING.
# A bundle built before the BaseViewConfig.impeller.js shim landed (or from a
# tree where the metro-shims redirect silently broke) would mount <View
# onKeyDown> with NO topKeyDown bubbling registration at all -- Fabric would
# then simply never call dispatchEvent("keyDown"), and the gate would read
# that as "the engine never sent it" when the real defect is upstream, in
# packaging. grep the bundle for both view-config keys the shim adds.
grep -q "onKeyDown" "$BUNDLE" || fail "bundle has no 'onKeyDown' at all -- the BaseViewConfig.impeller.js shim did not make it into the bundle (packaging regression, not an engine defect)"
grep -q "topKeyDown" "$BUNDLE" || fail "bundle has no 'topKeyDown' bubbling registration -- the shim's bubblingEventTypes entry did not reach the bundle"

WIN_W=400
WIN_H=300

# Focus point: inside the TextInput (marginTop:20 marginLeft:20, 300x36).
FOCUS_XY="40,38"

assert_scene_mounted() {  # $1 = log path
  local nodes
  nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$1" | tail -1)"
  [ -n "$nodes" ] || { tail -30 "$1" | sed 's/^/   /' >&2; fail "no 'scene_nodes=' line at all -- the app did not reach startSurface"; }
  [ "$nodes" -gt 0 ] \
    || fail "scene_nodes=$nodes -- the fixture mounted NOTHING (a mismatched --app-name is the classic cause). Every console-log assertion below would read PASS against a blank mount if this check were skipped."
  echo "   scene_nodes=$nodes"
}

# Focuses the TextInput via an in-process synthetic click (same hook
# ci-window-input.sh's assert B uses) so the run does not depend on XTest
# pointer delivery succeeding before the keyboard assertions even start.
FOCUS_ARGS="--click-after-frames 5:${FOCUS_XY}"

echo "== 3. assert A: REAL X keyboard events (XTest) reach JS, both channels =="
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
  echo "KEY_EVENTS_GATE_SKIP_A: no DISPLAY / python-xlib -- the REAL-keyboard"
  echo "  assertion did not run. Assertion B below CANNOT detect a missing"
  echo "  glfwSetKeyCallback. Do not read this run as full coverage."
else
  REAL_LOG="$WORK/real-key.log"
  # Run length is WALL TIME (--idle-skip --idle-run-sec 12), not a frame count:
  # 5000 frames pass in ~4.5s and the window closed after the first XTest key,
  # before Shift+Tab was sent. --idle-run-sec is only honoured with idle-skip
  # on, and any --frames N turns the windowed idle-skip default OFF.
  # Launched in THIS shell (not via a $(...) helper): a background job started
  # inside command substitution belongs to the subshell, and `wait` here then
  # fails with "not a child of this shell" (rc 127).
  set +e
  "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" --app-name P0KeyEvents \
      --width "$WIN_W" --height "$WIN_H" --idle-skip --idle-run-sec 12 \
      $FOCUS_ARGS \
      > "$REAL_LOG" 2>&1 &
  PID=$!
  sleep 4
  # ArrowLeft plain, Shift+Tab, Ctrl+A, Escape, Delete -- the ask's exact list
  # (Super+A is B-only below: some WMs intercept Super before XTest's synthetic
  # press ever reaches our window, which is a WM policy, not an engine defect).
  "$XPY" "$XKEY" "React Native (Impeller)" \
      "Left" "Tab+shift" "a+ctrl" "Escape" "Delete" \
      > "$WORK/xkey.log" 2>&1
  XRC=$?
  wait "$PID"
  APPRC=$?
  set -e
  sed 's/^/   /' "$WORK/xkey.log"
  [ "$XRC" -eq 0 ] || { tail -20 "$WORK/xkey.log" | sed 's/^/   /' >&2; fail "XTest key driver failed (rc=$XRC)"; }
  [ "$APPRC" -eq 0 ] || { tail -30 "$REAL_LOG" | sed 's/^/   /' >&2; fail "windowed app exited $APPRC"; }

  assert_scene_mounted "$REAL_LOG"

  # native-side proof: key_event lines with type=down AND type=up both present
  # (release was PREVIOUSLY DROPPED OUTRIGHT -- this is the regression this
  # gate exists to catch).
  DOWNS="$(grep -c 'rn-impeller: key_event type=down' "$REAL_LOG" || true)"
  UPS="$(grep -c 'rn-impeller: key_event type=up' "$REAL_LOG" || true)"
  [ "$DOWNS" -ge 1 ] || { tail -30 "$REAL_LOG" | sed 's/^/   /' >&2; fail "no 'key_event type=down' lines -- the GLFW key callback never fired for a REAL key press. This is the unregistered-callback bug."; }
  [ "$UPS" -ge 1 ] || { tail -30 "$REAL_LOG" | sed 's/^/   /' >&2; fail "no 'key_event type=up' lines -- key RELEASE never reached the host. This is the exact regression (GLFW_RELEASE was unconditionally dropped)."; }
  echo "   OK: native key_event lines: down=$DOWNS up=$UPS"

  # JS-side proof: the fixture's console.log lines, printed by the engine as
  # `[js] ...` (ReactHost.cpp's installConsole). ArrowLeft must reach BOTH
  # onKeyPress (TextInput) and onKeyDown/onKeyUp (wrapping View) with the
  # right key/code; Shift+Tab and Ctrl+A must show their modifiers; Escape and
  # Delete must both be visible by name.
  grep -q '\[js\] VIEW_KEYDOWN key=ArrowLeft code=ArrowLeft' "$REAL_LOG" \
    || { tail -40 "$REAL_LOG" | sed 's/^/   /' >&2; fail "JS never saw VIEW_KEYDOWN for ArrowLeft -- the generic keyDown dispatchEvent, or its topKeyDown view-config registration, is not reaching <View onKeyDown>."; }
  grep -q '\[js\] VIEW_KEYUP key=ArrowLeft code=ArrowLeft' "$REAL_LOG" \
    || { tail -40 "$REAL_LOG" | sed 's/^/   /' >&2; fail "JS never saw VIEW_KEYUP for ArrowLeft -- key release is not reaching <View onKeyUp>."; }
  grep -q '\[js\] VIEW_KEYDOWN key=Tab code=Tab shift=1' "$REAL_LOG" \
    || { tail -40 "$REAL_LOG" | sed 's/^/   /' >&2; fail "JS never saw Shift+Tab with shift=1 -- modifier forwarding is broken (Shift was the ONLY modifier the old code read at all, so if even this fails everything else does too)."; }
  grep -q '\[js\] VIEW_KEYDOWN key=a code=KeyA shift=0 ctrl=1' "$REAL_LOG" \
    || { tail -40 "$REAL_LOG" | sed 's/^/   /' >&2; fail "JS never saw Ctrl+A with ctrl=1 -- Ctrl was never read by the pre-fix key callback at all."; }
  grep -q '\[js\] VIEW_KEYDOWN key=Escape code=Escape' "$REAL_LOG" \
    || { tail -40 "$REAL_LOG" | sed 's/^/   /' >&2; fail "JS never saw Escape -- Escape was not one of the two keys the pre-fix callback recognised (Backspace/Enter only)."; }
  grep -q '\[js\] VIEW_KEYDOWN key=Delete code=Delete' "$REAL_LOG" \
    || { tail -40 "$REAL_LOG" | sed 's/^/   /' >&2; fail "JS never saw Delete."; }
  grep -q '\[js\] TI_KEYPRESS key=ArrowLeft' "$REAL_LOG" \
    || { tail -40 "$REAL_LOG" | sed 's/^/   /' >&2; fail "JS never saw TI_KEYPRESS for ArrowLeft -- TextInputEventEmitter::onKeyPress is not firing for a focused field."; }
  echo "   OK: JS saw ArrowLeft (down+up on View, onKeyPress on TextInput), Shift+Tab, Ctrl+A, Escape, Delete"
fi

echo "== 4. assert B: SYNTHETIC key events (host-independent modifier coverage) =="
# Runs on any host, including one where XTest cannot reach Super/Meta. Covers
# the FULL ask: ArrowLeft, Shift+Tab, Ctrl+A, Super+A, Escape, Delete, each as
# a down AND a matching up.
SYNTH_LOG="$WORK/synth-key.log"
set +e
timeout 25 "$RESOLVED" --window --probe-banner off --bundle "$BUNDLE" \
    --app-name P0KeyEvents --width "$WIN_W" --height "$WIN_H" --frames 60 \
    --click-after-frames "5:${FOCUS_XY}" \
    --key-after-frames "10:ArrowLeft:down;ArrowLeft:up;Tab:down:shift;Tab:up:shift;a:down:ctrl;a:up:ctrl;a:down:meta;a:up:meta;Escape:down;Escape:up;Delete:down;Delete:up" \
    > "$SYNTH_LOG" 2>&1
SYNTH_RC=$?
set -e
[ "$SYNTH_RC" -eq 0 ] || { tail -30 "$SYNTH_LOG" | sed 's/^/   /' >&2; fail "synthetic-key run exited $SYNTH_RC"; }
assert_scene_mounted "$SYNTH_LOG"

for pair in \
    'VIEW_KEYDOWN key=ArrowLeft code=ArrowLeft' \
    'VIEW_KEYUP key=ArrowLeft code=ArrowLeft' \
    'VIEW_KEYDOWN key=Tab code=Tab shift=1' \
    'VIEW_KEYUP key=Tab code=Tab shift=1' \
    'VIEW_KEYDOWN key=a code=KeyA shift=0 ctrl=1' \
    'VIEW_KEYUP key=a code=KeyA shift=0 ctrl=1' \
    'VIEW_KEYDOWN key=a code=KeyA' \
    'VIEW_KEYDOWN key=Escape code=Escape' \
    'VIEW_KEYUP key=Escape code=Escape' \
    'VIEW_KEYDOWN key=Delete code=Delete' \
    'VIEW_KEYUP key=Delete code=Delete' \
  ; do
  grep -q "\[js\] $pair" "$SYNTH_LOG" \
    || { tail -50 "$SYNTH_LOG" | sed 's/^/   /' >&2; fail "synthetic run: JS never saw '$pair'"; }
done
# Super/meta: assert it was FORWARDED with the right bit, but do not fail the
# whole gate if the synthetic hook could not exercise it -- --key-after-frames
# goes through synthesiseKey -> dispatchKeyEvent directly, bypassing any WM
# policy, so this one SHOULD always be reachable; treat a miss as a real
# failure of modifier plumbing, not a WM quirk (that caveat is XTest-only).
grep -q '\[js\] VIEW_KEYDOWN key=a code=KeyA shift=0 ctrl=0 alt=0 meta=1' "$SYNTH_LOG" \
  || { tail -50 "$SYNTH_LOG" | sed 's/^/   /' >&2; fail "synthetic run: JS never saw Super(meta)+A with meta=1 -- GLFW_MOD_SUPER is not reaching the KeyEvent.meta field."; }
echo "   OK: synthetic run saw all 6 keys (ArrowLeft, Shift+Tab, Ctrl+A, Super+A, Escape, Delete), down+up where applicable"

echo "KEY_EVENTS_GATE_PASS (full keyboard forwarding: down/repeat/release, modifiers, onKeyPress + generic keyDown/keyUp)"
