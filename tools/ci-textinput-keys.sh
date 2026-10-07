#!/usr/bin/env bash
# ENG-24 gate: multiline TextInput Enter/Shift+Enter per submitBehavior,
# onKeyPress with key + shiftKey, onContentSizeChange, and single-line
# caret-follow scroll. Every arm is a WINDOWED --type run (ENG-18) except H.
#
# THE BUG (ENGINE-LEDGER ENG-24, measured CHAT-2 2026-10-06).
#  (a) Enter AND Shift+Enter in a multiline field fired onSubmitEditing and
#      inserted nothing, whatever submitBehavior said.
#  (b) onKeyPress had no shiftKey (RN core's KeyPressMetrics is text +
#      eventCount only).
#  (c) onContentSizeChange never fired, and a single-line field wrapped its
#      value at the box and clipped instead of scrolling to the caret.
#
# Fixture fixtures/eng24-textinput-keys (controlled fields that log every
# event as `[js] ENG24 <id> ...`). Boxes (x 20..320): NL y 10..100 multiline
# 'newline'; SUB y 110..200 multiline 'submit'; BLUR y 210..270 multiline
# 'blurAndSubmit'; LONG y 280..316 single-line; GROW y 330..510 multiline.
#
#   A. NL: a, Shift+Enter, b -> value "a\nb", NO onSubmitEditing, two lines
#      of ink in the box; onKeyPress key=Enter shift=1.
#   B. NL: a, Shift+Enter -> the caret is painted on LINE 2.
#   C. SUB ('submit'): a, Enter, Shift+Enter, b -> onSubmitEditing exactly
#      once, after Enter; Shift+Enter still breaks the line -> "a\nb";
#      onKeyPress key=Enter shift=0 then shift=1.
#   D. BLUR ('blurAndSubmit'): a, Enter -> onSubmitEditing once, then onBlur.
#   E. GROW: 8 lines -> onContentSizeChange fires with a rising height, one
#      step per line, 7 steps of at least 12 pt.
#   F. LONG single-line: 115 dots + MMMMM -> one line of ink, the Ms painted
#      inside the box's right end, no ink below or right of the box.
#   G. CONTROL for F: the same run's LEFT end holds only dots (the text did
#      scroll; a box showing the start would hold dots everywhere and no Ms).
#   H. Headless --type a<S-CR>b in NL gives the same "a\nb" + shift=1.
#
# The Mac runs: RNI_BIN=<darwin rn-impeller> bash tools/ci-textinput-keys.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "TEXTINPUT_KEYS_GATE_FAIL: $*" >&2; exit 1; }

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

run_win() {  # run_win <name> <type-spec>: windowed --type + --screenshot
  local name="$1" spec="$2" log="$WORK/$1.log" rc
  set +e
  if [ "$OS" = Darwin ]; then
    ( cd "$(dirname "$BIN")" && zsh "$ROOT/tools/darwin-run-interactive.sh" "$log" 60 -- \
        "$BIN" "${COMMON[@]}" --window --type "$spec" --screenshot "$WORK/$name.ppm" ) > /dev/null 2>&1
  elif command -v xvfb-run > /dev/null; then
    timeout 60 xvfb-run -a -s "-screen 0 1280x1024x24" "$BIN" "${COMMON[@]}" --window \
      --type "$spec" --screenshot "$WORK/$name.ppm" > "$log" 2>&1
  else
    DISPLAY="${DISPLAY:-:0}" timeout 60 "$BIN" "${COMMON[@]}" --window \
      --type "$spec" --screenshot "$WORK/$name.ppm" > "$log" 2>&1
  fi
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -15 "$log" >&2; fail "$name: windowed run exited $rc"; }
  grep -q '^rn-impeller: type_done ' "$log" || fail "$name: the --type plan never finished"
}
ink() { python3 tools/ti-ink.py "$@"; }
field() { sed -n "s/.*$1=\\([-0-9.]*\\).*/\\1/p" <<< "$2"; }
value_of() { sed -n 's/^rn-impeller: textinput_value .* v=\(.*\)$/\1/p' "$1" | tail -1; }

echo "== A. NL multiline 'newline': a, Shift+Enter, b =="
run_win a '60,40:a<S-CR>b'
[ "$(value_of "$WORK/a.log")" = 'a\nb' ] || fail "A: value is '$(value_of "$WORK/a.log")', want 'a\\nb' (Shift+Enter did not break the line)"
grep -q '^\[js\] ENG24 NL change="a\\nb"$' "$WORK/a.log" || fail "A: JS onChangeText never saw \"a\\nb\""
! grep -q '^\[js\] ENG24 NL submit' "$WORK/a.log" || fail "A: onSubmitEditing fired on Shift+Enter in a multiline field"
grep -q '^\[js\] ENG24 NL key=Enter shift=1$' "$WORK/a.log" || fail "A: onKeyPress did not report key=Enter shiftKey=true"
A_INK="$(ink "$WORK/a.ppm" 22 12 318 98)"; echo "   NL box: $A_INK"
a_rows="$(python3 -c "import re,sys; m=re.search(r'rows=([-0-9.]+)-([-0-9.]+)', sys.argv[1]); print(float(m.group(2))-float(m.group(1)))" "$A_INK")"
python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) >= 25 else 1)" "$a_rows" \
  || fail "A: the NL box's ink spans $a_rows pt of rows; two lines need >= 25 (b is not on line 2)"
echo "   OK"

echo "== B. NL: a, Shift+Enter -> caret on line 2 =="
run_win b '60,40:a<S-CR>'
[ "$(value_of "$WORK/b.log")" = 'a\n' ] || fail "B: value is '$(value_of "$WORK/b.log")', want 'a\\n'"
# NL content box starts at y 19 (top 10 + border 1 + padding 8); a line is
# ~18 pt. Line 2's first columns hold only the caret when it moved down.
B_L1="$(ink "$WORK/b.ppm" 22 19 318 37)"; B_L2="$(ink "$WORK/b.ppm" 22 38 30 56)"
echo "   line 1: $B_L1"; echo "   line 2 start: $B_L2"
[ "$(field ink "$B_L1")" -ge 10 ] || fail "B: no 'a' ink on line 1"
[ "$(field ink "$B_L2")" -ge 8 ] || fail "B: no caret at the start of line 2 (the caret stayed on line 1)"
echo "   OK"

echo "== C. SUB multiline 'submit': a, Enter, Shift+Enter, b =="
run_win c '60,140:a<CR><S-CR>b'
n_sub="$(grep -c '^\[js\] ENG24 SUB submit' "$WORK/c.log" || true)"
[ "$n_sub" -eq 1 ] || fail "C: onSubmitEditing fired $n_sub times, want exactly 1 (Enter submits, Shift+Enter breaks the line)"
grep -q '^\[js\] ENG24 SUB change="a\\n"$' "$WORK/c.log" && ! grep -q '^\[js\] ENG24 SUB change="a\\n\\n' "$WORK/c.log" \
  || fail "C: Enter inserted a newline in a 'submit' field, or Shift+Enter did not"
[ "$(value_of "$WORK/c.log")" = 'a\nb' ] || fail "C: value is '$(value_of "$WORK/c.log")', want 'a\\nb'"
grep -q '^\[js\] ENG24 SUB key=Enter shift=0$' "$WORK/c.log" && grep -q '^\[js\] ENG24 SUB key=Enter shift=1$' "$WORK/c.log" \
  || fail "C: onKeyPress shiftKey did not tell Enter (0) from Shift+Enter (1)"
echo "   OK"

echo "== D. BLUR multiline 'blurAndSubmit': a, Enter =="
run_win d '60,230:a<CR>'
grep -A3 '^\[js\] ENG24 BLUR submit n=1$' "$WORK/d.log" | grep -q '^\[js\] ENG24 BLUR blur$' \
  || fail "D: blurAndSubmit did not fire onSubmitEditing then onBlur"
! grep -q '^\[js\] ENG24 BLUR change="a\\n' "$WORK/d.log" || fail "D: blurAndSubmit inserted a newline"
echo "   OK"

echo "== E. GROW: 8 lines -> rising onContentSizeChange =="
run_win e '60,340:1<S-CR>2<S-CR>3<S-CR>4<S-CR>5<S-CR>6<S-CR>7<S-CR>8'
grep -o '^\[js\] ENG24 GROW csize w=[0-9.]* h=[0-9.]*' "$WORK/e.log" | sed 's/.*h=//' > "$WORK/e.h"
echo "   heights: $(tr '\n' ' ' < "$WORK/e.h")"
python3 - "$WORK/e.h" <<'PY' || fail "E: onContentSizeChange heights do not rise one step per line (see above)"
import sys
h = [float(x) for x in open(sys.argv[1]).read().split()]
steps = [b - a for a, b in zip(h, h[1:])]
ok = len(h) >= 8 and all(s >= 12 for s in steps) and len([s for s in steps if s >= 12]) >= 7
sys.exit(0 if ok else 1)
PY
echo "   OK"

echo "== F/G. LONG single-line: 115 dots + MMMMM =="
LONGSPEC="60,298:$(python3 -c "print('.' * 115 + 'MMMMM')")"
run_win f "$LONGSPEC"
grep -qE '^rn-impeller: textinput_value tag=[0-9]+ len=120 caret=120 ' "$WORK/f.log" || fail "F: the field does not hold 120 chars"
F_ALL="$(ink "$WORK/f.ppm" 21 281 319 315)"; F_END="$(ink "$WORK/f.ppm" 260 281 319 315)"
F_START="$(ink "$WORK/f.ppm" 21 281 80 315)"
F_BELOW="$(ink "$WORK/f.ppm" 21 317 399 329)"; F_RIGHT="$(ink "$WORK/f.ppm" 321 270 399 330)"
echo "   box: $F_ALL"; echo "   right end: $F_END"; echo "   left end: $F_START"
echo "   below box: $F_BELOW"; echo "   right of box: $F_RIGHT"
[ "$(field bands "$F_ALL")" -eq 1 ] || fail "F: $(field bands "$F_ALL") ink bands in a single-line box, want 1 (it wrapped)"
[ "$(field ink "$F_END")" -ge 100 ] || fail "F: only $(field ink "$F_END") ink px at the box's right end: the last glyphs (MMMMM) are not in view"
[ "$(field ink "$F_BELOW")" -eq 0 ] || fail "F: ink below the box: the value wrapped out of the field"
[ "$(field ink "$F_RIGHT")" -eq 0 ] || fail "F: ink right of the box: the text is not clipped"
[ "$(field ink "$F_START")" -lt "$(field ink "$F_END")" ] && [ "$(field ink "$F_START")" -lt 60 ] \
  || fail "G: the box's left end holds as much ink as the right end: it shows the start, not the caret"
echo "   OK"

echo "== H. headless --type a<S-CR>b in NL =="
set +e; "$BIN" "${COMMON[@]}" --headless --type '60,40:a<S-CR>b' > "$WORK/h.log" 2>&1; rc=$?; set -e
[ "$rc" -eq 0 ] || { tail -15 "$WORK/h.log" >&2; fail "H: headless run exited $rc"; }
[ "$(value_of "$WORK/h.log")" = 'a\nb' ] || fail "H: headless value is '$(value_of "$WORK/h.log")', want 'a\\nb'"
grep -q '^\[js\] ENG24 NL key=Enter shift=1$' "$WORK/h.log" || fail "H: headless onKeyPress lacks shift=1"
echo "   OK"

echo "TEXTINPUT_KEYS_GATE_PASS (submitBehavior newline/submit/blurAndSubmit, Shift+Enter, onKeyPress shiftKey, onContentSizeChange, single-line caret follow)"
