#!/usr/bin/env bash
# ENG-18 gate: --type works in a WINDOWED run, through the real windowed
# entry points, and the capture shows the typed text.
#
# THE BUG. --type X,Y:SEQ was read only by the headless probe. RunWindowed
# never saw it, so `--window --type ... --screenshot out.ppm` typed nothing
# and (with no --screenshot-after) captured nothing. Input checks and their
# captures could not come from one run (ENGINE-LEDGER ENG-18).
#
# THE FIX. main.cpp parses SEQ once (ParseTypeSeq) for both modes. Windowed,
# it settles the mount, focuses the field at X,Y (layout points), then feeds
# one token per frame: characters through GlfwSurface::synthesiseChar, and
# <BS>/<CR>/<S-CR> through GlfwSurface::synthesiseKey (the key callback's own
# translation, so onKeyPress, keyDown and the editing handler all run). It
# prints textinput_value like headless, captures --screenshot two frames after
# the last token, and exits.
#
#   A. --window --type 60,40:AB --screenshot: exits 0 by itself, logs
#      textinput_value v=AB, JS onChangeText saw "AB", and the capture has one
#      band of ink inside the NL field.
#   B. CONTROL: the same window with no --type has NO ink in that field, so
#      arm A's ink is the typing, not the fixture.
#   C. <BS> goes through the KEY path: ABC<BS> leaves v=AB, and the log shows
#      key_event type=down key=Backspace (synthesiseKey -> dispatchKeyEvent),
#      not a direct buffer edit.
#   D. Headless --type with the same spec still gives v=AB (one parser).
#
# Fixture fixtures/eng24-textinput-keys (prebuilt bundle, no npm).
# The Mac runs: RNI_BIN=<darwin rn-impeller> bash tools/ci-window-type.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "WINDOW_TYPE_GATE_FAIL: $*" >&2; exit 1; }

OS="$(uname -s)"
if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"
elif [ "$OS" = Darwin ]; then BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
BUNDLE="${RNI_TEST_BUNDLE:-$ROOT/fixtures/eng24-textinput-keys/prebuilt/eng24-textinput-keys.bundle}"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

WORK="$(mktemp -d)"
cleanup() { rni_kill_own; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

COMMON=(--bundle "$BUNDLE" --app-name Eng24TextInputKeys --probe-banner off
        --width 400 --height 520 --scale 1 --supersample-rnsvg 0)

# run_win <log> <args...>: one windowed run, 60 s cap.
run_win() {
  local log="$1"; shift
  if [ "$OS" = Darwin ]; then
    ( cd "$(dirname "$BIN")" && zsh "$ROOT/tools/darwin-run-interactive.sh" "$log" 60 -- "$BIN" "$@" ) > /dev/null 2>&1
  elif command -v xvfb-run > /dev/null; then
    timeout 60 xvfb-run -a -s "-screen 0 1280x1024x24" "$BIN" "$@" > "$log" 2>&1
  else
    DISPLAY="${DISPLAY:-:0}" timeout 60 "$BIN" "$@" > "$log" 2>&1
  fi
}

# NL field box: x 20..320, y 10..100; content inside the 1 pt border.
NLBOX=(22 12 318 98)

echo "== A. windowed --type AB + --screenshot =="
set +e; run_win "$WORK/a.log" "${COMMON[@]}" --window --type '60,40:AB' --screenshot "$WORK/a.ppm"; rc=$?; set -e
grep -E 'type_|textinput_value|ENG24|screenshot=|WINDOW_OK' "$WORK/a.log" | sed 's/^/   /' || true
[ "$rc" -eq 0 ] || { tail -15 "$WORK/a.log" >&2; fail "A: windowed --type run exited $rc"; }
grep -qE '^rn-impeller: textinput_value tag=[0-9]+ len=2 caret=2 v=AB$' "$WORK/a.log" \
  || fail "A: no 'textinput_value ... v=AB' line: the windowed run did not type"
grep -q '^\[js\] ENG24 NL change="AB"$' "$WORK/a.log" \
  || fail "A: JS onChangeText never saw \"AB\""
[ -s "$WORK/a.ppm" ] || fail "A: --screenshot wrote no frame"
A_INK="$(python3 tools/ti-ink.py "$WORK/a.ppm" "${NLBOX[@]}")"
echo "   NL field: $A_INK"
a_ink="$(sed 's/^ink=\([0-9]*\).*/\1/' <<< "$A_INK")"
a_bands="$(sed 's/.*bands=\([0-9]*\).*/\1/' <<< "$A_INK")"
[ "$a_ink" -ge 40 ] || fail "A: the capture shows only $a_ink ink px in the NL field (want >= 40): AB is not on screen"
[ "$a_bands" -eq 1 ] || fail "A: $a_bands ink bands in the NL field, want 1 line"

echo "== B. control: same window, no --type =="
set +e; run_win "$WORK/b.log" "${COMMON[@]}" --window --frames 8 --screenshot-after 0 --screenshot "$WORK/b.ppm"; rc=$?; set -e
[ "$rc" -eq 0 ] || { tail -15 "$WORK/b.log" >&2; fail "B: control run exited $rc"; }
B_INK="$(python3 tools/ti-ink.py "$WORK/b.ppm" "${NLBOX[@]}")"
echo "   NL field: $B_INK"
b_ink="$(sed 's/^ink=\([0-9]*\).*/\1/' <<< "$B_INK")"
[ "$b_ink" -le 5 ] || fail "B: the untyped NL field already holds $b_ink ink px; arm A's ink proves nothing"

echo "== C. <BS> through the key path =="
set +e; run_win "$WORK/c.log" "${COMMON[@]}" --window --type '60,40:ABC<BS>'; rc=$?; set -e
[ "$rc" -eq 0 ] || { tail -15 "$WORK/c.log" >&2; fail "C: run exited $rc"; }
grep -qE '^rn-impeller: textinput_value tag=[0-9]+ len=2 caret=2 v=AB$' "$WORK/c.log" \
  || fail "C: ABC<BS> did not leave v=AB: $(grep textinput_value "$WORK/c.log")"
grep -qE '^rn-impeller: key_event type=down key=Backspace ' "$WORK/c.log" \
  || fail "C: no key_event for Backspace: <BS> skipped the real key path"
grep -q '^\[js\] ENG24 NL change="AB"$' "$WORK/c.log" || fail "C: JS never saw the backspaced value"
echo "   OK"

echo "== D. headless --type, same spec =="
set +e; "$BIN" "${COMMON[@]}" --headless --type '60,40:AB' > "$WORK/d.log" 2>&1; rc=$?; set -e
[ "$rc" -eq 0 ] || { tail -15 "$WORK/d.log" >&2; fail "D: headless run exited $rc"; }
grep -qE '^rn-impeller: textinput_value tag=[0-9]+ len=2 caret=2 v=AB$' "$WORK/d.log" \
  || fail "D: headless --type no longer types AB"
echo "   OK"

echo "WINDOW_TYPE_PASS"
