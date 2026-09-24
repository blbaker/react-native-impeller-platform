#!/usr/bin/env bash
# ENG-01b GATE: single-line text editing in react-native-impeller.
#
# The peer's ask (skia-platform P7-02a/02b as the REFERENCE design): a focused
# <TextInput> accepts characters, Backspace erases, Enter submits, and the
# controlled field's onChangeText re-renders React state. This gate proves the
# WHOLE loop headlessly through --type X,Y:SEQ, which drives the exact
# FabricHost::focusTextInputAt / dispatchKey path the GLFW char/key callbacks
# call in a real window (engine/host/GlfwSurface.cpp). No window required.
#
# ⛔ WHY EACH ASSERTION IS DISTINCT — the failure modes it alone can see:
#
#   A. THE BUFFER CHANGED. Chars typed into a focused field land in the paint
#      buffer (textinput_value len/v). Dies if the char callback is unregistered
#      or dispatchKey never mutates the SceneGraph — the "focused field paints a
#      caret and swallows every keystroke" state the Mac gate was pinned to.
#
#   B. THE CARET ADVANCED. len alone cannot see a buffer that grows while the
#      caret stays at 0 (an append-at-wrong-index bug). caret must equal len
#      after a pure-append+erase sequence. This is why main.cpp emits caret=.
#
#   C. onChangeText ACTUALLY RAN IN JS. The fixture is CONTROLLED: value={v},
#      onChangeText={setV}, and a <Text> renders `len=${v.length} v=${v}`. If
#      that label matches the engine buffer, JS re-rendered — proving onChange
#      fired, not merely that the native buffer changed behind JS's back. This
#      is the effect-(2) half of dispatchKey; effect (1) alone passes A+B and
#      still leaves a controlled field frozen on screen.
#
#   D. BACKSPACE ERASES. 'Hi'+<BS>+'ey' must yield 'Hey', not 'Hiey' or 'Hi'.
#
#   E. ENTER SUBMITS WITHOUT MUTATING. onSubmitEditing fires (submitted=yes) and
#      the buffer is unchanged — a bare Enter that appended '\n' or cleared the
#      field would be a real bug this arm alone catches.
#
#   F. FOCUS GATES INPUT (negative control). Typing with nothing focused
#      (type_focus=0) changes no buffer and fires no event. Without this arm, a
#      pass could mean "types into a global buffer regardless of focus", which
#      is not text editing.
#
# The B/C split mirrors the peer's own dual-effect discipline (dispatchScroll):
# a green A+D+E with C failing is the single most likely wrong-but-plausible
# implementation — native buffer edits that never reach React — so C is the arm
# that actually earns the row.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p9-textinput"

fail() { echo "TEXTEDIT_GATE_FAIL: $*" >&2; exit 1; }

# The field is at marginTop:20 marginLeft:20, 300x36 — its centre is ~(170,38)
# in points. 40,38 is inside its left edge; 380,290 is the far corner, off it.
FIELD_XY="40,38"
EMPTY_XY="380,290"

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
APP="$WORK/EditApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="editapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9TextInput"; a.displayName="P9TextInput";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the ENG-01b controlled-edit fixture as the app entry =="
cp "$FIXTURE/edit.js" "$APP/index.js"
npx --no-install react-native init-impeller > /dev/null 2>&1 || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/edit.bundle \
    > /dev/null 2>&1
BUNDLE="$APP/impeller/build/edit.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"
cd "$ROOT"

# Runs one --type sequence headlessly and captures the machine-readable report.
run_type() {  # $1 = "X,Y:SEQ"   $2 = log path
  set +e
  "$RESOLVED" --headless --probe-banner off --bundle "$BUNDLE" \
              --app-name P9TextInput --width 400 --height 300 \
              --type "$1" > "$2" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$2" | sed 's/^/   /' >&2; fail "--type $1 exited $rc"; }
}

# Field accessors over one report file.
ti_len()   { sed -n 's/^rn-impeller: textinput_value .* len=\([0-9]*\) .*/\1/p'   "$1" | tail -1; }
ti_caret() { sed -n 's/^rn-impeller: textinput_value .* caret=\([0-9]*\) .*/\1/p' "$1" | tail -1; }
ti_val()   { sed -n 's/^rn-impeller: textinput_value .* v=\(.*\)$/\1/p'           "$1" | tail -1; }
ti_focus() { sed -n 's/^rn-impeller: type_focus=\([0-9-]*\) .*/\1/p'              "$1" | tail -1; }
js_label() { sed -n 's/^rn-impeller: paragraph_text tag=[0-9]* "\(len=.*\)"$/\1/p' "$1" | tail -1; }
js_submit(){ sed -n 's/^rn-impeller: paragraph_text tag=[0-9]* "submitted=\(yes\|no\)"$/\1/p' "$1" | tail -1; }

echo "== 3. assert A+B+C+D: type 'Hi', Backspace, 'ey' -> 'Hey' =="
EDIT_LOG="$WORK/edit.log"
run_type "${FIELD_XY}:Hi<BS>ey" "$EDIT_LOG"

FOCUS="$(ti_focus "$EDIT_LOG")"
SETTLE="$(sed -n 's/^rn-impeller: type_mount_settle_ms=\([0-9]*\) field=\([0-9-]*\)/settle=\1ms field=\2/p' "$EDIT_LOG" | tail -1)"
[ -n "$FOCUS" ] && [ "$FOCUS" -gt 0 ] \
  || fail "type_focus=$FOCUS ($SETTLE) — the click at $FIELD_XY did not focus the field. If field=0 after a ~10000ms settle, the TextInput never laid out under the point (layout/registration bug: TextInputComponentDescriptor missing → field mounts 0x0 as a plain View and the paragraphs collapse over it). If field=1 here, the field was present but focusTextInputAt rejected it (not recognised as a TextInputEventEmitter)."

VAL="$(ti_val "$EDIT_LOG")"
LEN="$(ti_len "$EDIT_LOG")"
CARET="$(ti_caret "$EDIT_LOG")"
[ "$VAL" = "Hey" ] \
  || fail "A/D: buffer should be 'Hey' after 'Hi'+<BS>+'ey'; got '$VAL'. Either a keystroke never reached the buffer (char callback unregistered / dispatchKey no-op) or Backspace did not erase."
[ "$LEN" = "3" ] \
  || fail "A: len should be 3 for 'Hey'; got $LEN."
[ "$CARET" = "3" ] \
  || fail "B: caret should be 3 (end of 'Hey') after a pure append+erase sequence; got $CARET. The buffer grew but the caret did not track it — an insert-at-wrong-index bug len alone cannot see."

JS_LABEL="$(js_label "$EDIT_LOG")"
[ "$JS_LABEL" = "len=3 v=Hey" ] \
  || fail "C: the CONTROLLED label rendered '$JS_LABEL', not 'len=3 v=Hey'. The engine buffer changed but onChange never re-rendered React state — a native-only edit JS is deaf to. This is the effect-(2) half of dispatchKey (te->onChange); effect (1) alone passes A/B/D and still freezes the field on screen."
echo "   OK: 'Hi'+<BS>+'ey' -> buffer='Hey' len=3 caret=3, JS label 'len=3 v=Hey' (onChangeText ran)"

echo "== 4. assert E: Enter submits without mutating the buffer =="
SUBMIT_LOG="$WORK/submit.log"
run_type "${FIELD_XY}:ok<CR>" "$SUBMIT_LOG"
S_VAL="$(ti_val "$SUBMIT_LOG")"
S_SUBMIT="$(js_submit "$SUBMIT_LOG")"
[ "$S_VAL" = "ok" ] \
  || fail "E: a bare Enter must not alter the buffer; after 'ok'+<CR> the value is '$S_VAL', not 'ok'. Enter appended a newline or cleared the field instead of submitting."
[ "$S_SUBMIT" = "yes" ] \
  || fail "E: onSubmitEditing never fired — submitted=$S_SUBMIT after Enter. dispatchKey's Submit path did not schedule te->onSubmitEditing."
echo "   OK: Enter -> submitted=yes, buffer unchanged ('ok')"

echo "== 5. assert F (negative control): typing with nothing focused is a no-op =="
NOFOCUS_LOG="$WORK/nofocus.log"
run_type "${EMPTY_XY}:zzz" "$NOFOCUS_LOG"
NF_FOCUS="$(ti_focus "$NOFOCUS_LOG")"
NF_LABEL="$(js_label "$NOFOCUS_LOG")"
[ "$NF_FOCUS" = "0" ] \
  || fail "F: a click at $EMPTY_XY (off the field) should focus nothing; type_focus=$NF_FOCUS. Focus hit-testing is grabbing a field it should not."
[ "$NF_LABEL" = "len=0 v=" ] \
  || fail "F: 'zzz' typed with no focus changed the controlled label to '$NF_LABEL'. Input is not gated by focus — characters go somewhere regardless, which is not text editing."
echo "   OK: no focus -> nothing typed (focus gates input)"

echo "TEXTEDIT_GATE_PASS: focus + char + backspace + caret + onChangeText + submit, all verified headlessly"
