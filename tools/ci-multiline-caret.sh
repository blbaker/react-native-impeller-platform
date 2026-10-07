#!/usr/bin/env bash
# ENG-25 gate: a MULTILINE <TextInput>'s caret, click hit test, selection
# rects and Up/Down use the SAME wrapped paragraph the painter draws.
#
# THE BUG (Baker, HostApp chat composer): "The text visually wraps but the cursor
# continues into that hidden overflow. If I click on the second line, the
# cursor always goes on the first line." Paint wrapped the paragraph to the
# box; the caret and the click mapping measured an UNWRAPPED single line.
#
# Fixture fixtures/eng25-multiline-caret: the Mac's probe (200 x 120 box at
# (20,20), fontSize 16, white on #222, 3 wrapped lines, no '\n').
#
# THE ORACLE IS THE PAINTED PIXELS, never the engine's own boundary report.
# Every run sets RNI_CARET_BLINK_MS=0 (solid caret), and the caret's painted
# box is the diff against the frame-0 (unfocused) screenshot of the same text.
#
#   A. End -> the caret paints INSIDE the box, on the LAST painted ink line,
#      right after its last glyph (pre-fix: off the right edge, line 1).
#   B. Click at box (30,50) (wrapped line 3) -> the caret paints under the
#      click; typing Z changes only line 3 and later, starting near the click
#      (pre-fix: caret and Z on line 1).
#   C. Up from line 3 -> one painted line up at about the same x; Up then
#      Down -> back on the exact same column.
#   D. Typing past the box width wraps a new painted line and the caret
#      follows onto it, inside the box.
#   E. Shift+Up from line 3 -> the highlight covers line 2 from the caret to
#      its end and line 3 from its start to the click, nothing on line 1.
#
# NO-NPM MODE: renders the committed prebuilt bundle with the staged binary.
#   RNI_BIN=<rn-impeller> bash tools/ci-multiline-caret.sh
# Needs a display (WSL: xvfb-run -a -s "-screen 0 1280x1024x24").
# Darwin (vsynced window): RNI_FRAMES=150 bash tools/ci-multiline-caret.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "MULTILINE_CARET_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/eng25-multiline-caret"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/eng25-multiline-caret.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  bash "$ROOT/tools/build-fixture-bundle.sh" eng25-multiline-caret Eng25MultilineCaret \
    || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
PX="python3 $ROOT/tools/eng25-caret-pixels.py"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

APP=Eng25MultilineCaret
# Box (20,20)-(220,140); text starts at x 24 (the 4 pt text inset).
BX0=20; BY0=20; BX1=220; BY1=140; TX0=24
CLICK_X=50; CLICK_Y=70   # box (30, 50): the Mac's "x=30, y=10+20*2"

run_win() {  # $1 = tag, rest = input flags. Writes $WORK/$1.{log,ppm} + -first.ppm
  local tag="$1"; shift
  set +e
  # RNI_FRAMES: the run must outlast the 1.5 s capture. 3000 frames is ~3 s
  # on linux/xvfb (no vsync); a vsynced darwin window wants ~150.
  RNI_CARET_BLINK_MS=0 "$ENGINE" --window --probe-banner off --bundle "$BUNDLE" \
    --app-name "$APP" --width 400 --height 300 --supersample-rnsvg 0 --scale 1 \
    --frames "${RNI_FRAMES:-3000}" --screenshot-first "$WORK/$tag-first.ppm" \
    --screenshot "$WORK/$tag.ppm" --screenshot-after 1500 "$@" > "$WORK/$tag.log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$WORK/$tag.log" >&2; fail "$tag: windowed run exited $rc"; }
  local n
  n="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORK/$tag.log" | tail -1)"
  [ -n "$n" ] && [ "$n" -gt 0 ] || fail "$tag: scene_nodes=${n:-none}: fixture did not mount"
  [ -s "$WORK/$tag.ppm" ] && [ -s "$WORK/$tag-first.ppm" ] || fail "$tag: no screenshot"
}
# Caret box = what changed vs the unfocused frame 0 (same text). "X0 Y0 X1 Y1 N".
caret_of() { $PX bbox "$WORK/$1-first.ppm" "$WORK/$1.ppm" 0 0 400 300; }
abs() { local v="$1"; echo "${v#-}"; }
last_change() { sed -n 's/^\[js\] ENG25 change=//p' "$WORK/$1.log" | tail -1; }

echo "== 0. paint oracle: the unfocused field's ink =="
run_win base
read -r INK_TOP INK_BOT INK_RIGHT <<< "$($PX ink "$WORK/base-first.ppm" $TX0 $BY0 $BX1 $BY1)"
[ -n "${INK_BOT:-}" ] || fail "0: no text ink inside the box"
[ $((INK_BOT - INK_TOP)) -ge 40 ] \
  || fail "0: ink spans rows $INK_TOP..$INK_BOT -- the fixture did not wrap to 3 lines"
echo "   OK: ink rows $INK_TOP..$INK_BOT inside the box"

echo "== A. End: caret on the LAST painted line, inside the box =="
run_win a --click-after-frames "5:200,130" --key-after-frames "10:End:down"
CA="$(caret_of a)"
[ "$CA" != "NONE" ] \
  || fail "A: End painted NO caret anywhere in the window (it walked off the right edge)"
read -r AX0 AY0 AX1 AY1 _ <<< "$CA"
[ "$AX1" -lt "$BX1" ] && [ "$AX0" -ge "$TX0" ] \
  || fail "A: End caret x $AX0..$AX1 is outside the box text area ($TX0..$BX1)"
[ "$AY0" -le "$INK_BOT" ] && [ "$INK_BOT" -le $((AY1 + 2)) ] \
  || fail "A: End caret rows $AY0..$AY1 are not on the last painted line (ink ends at row $INK_BOT)"
[ "$AY0" -gt $((INK_TOP + 10)) ] || fail "A: End caret is on the FIRST line (rows $AY0..$AY1)"
read -r _ _ LAST_RIGHT <<< "$($PX ink "$WORK/base-first.ppm" $TX0 "$AY0" $BX1 $((AY1 + 1)))"
[ "$AX0" -ge $((LAST_RIGHT - 1)) ] \
  || fail "A: End caret at x $AX0 sits before the last line's last glyph (ink to x $LAST_RIGHT)"
grep -q '^\[js\] ENG25 sel=77,77$' "$WORK/a.log" || fail "A: onSelectionChange never reported {77,77} (end)"
echo "   OK: caret x $AX0 rows $AY0..$AY1, after the last glyph (x $LAST_RIGHT), sel 77"

echo "== B. click wrapped line 3 at ($CLICK_X,$CLICK_Y), type Z =="
run_win b1 --click-after-frames "5:$CLICK_X,$CLICK_Y"
C3="$(caret_of b1)"
[ "$C3" != "NONE" ] || fail "B: the click painted no caret"
read -r CX0 CY0 CX1 CY1 _ <<< "$C3"
[ "$CY0" -le "$CLICK_Y" ] && [ "$CLICK_Y" -le "$CY1" ] \
  || fail "B: the click at y $CLICK_Y put the caret on rows $CY0..$CY1 -- another line (line 1 is the bug)"
[ "$(abs $((CX0 - CLICK_X)))" -le 8 ] \
  || fail "B: the click at x $CLICK_X put the caret at x $CX0"
run_win b2 --click-after-frames "5:$CLICK_X,$CLICK_Y" --char-after-frames "12:90"
case "$(last_change b2)" in *Z*) ;; *) fail "B: typing Z after the click changed nothing";; esac
read -r NUP _ <<< "$($PX rows "$WORK/b2-first.ppm" "$WORK/b2.ppm" $TX0 $BY0 $BX1 "$CY0")"
[ "$NUP" -eq 0 ] || fail "B: typing Z changed $NUP px ABOVE line 3 (lines 1-2) -- Z went to the wrong line"
read -r NL3 LX <<< "$($PX rows "$WORK/b2-first.ppm" "$WORK/b2.ppm" $TX0 "$CY0" $BX1 $((CY1 + 1)))"
[ "$NL3" -gt 0 ] || fail "B: typing Z changed nothing on line 3"
[ "$(abs $((LX - CX0)))" -le 8 ] \
  || fail "B: line 3 first changes at x $LX, not at the click (caret x $CX0)"
echo "   OK: caret x $CX0 rows $CY0..$CY1 under the click; Z changes line 3 from x $LX only"

echo "== C. Up from line 3, then Down back =="
run_win c1 --click-after-frames "5:$CLICK_X,$CLICK_Y" --key-after-frames "10:ArrowUp:down"
CU="$(caret_of c1)"
[ "$CU" != "NONE" ] || fail "C: Up painted no caret"
read -r UX0 UY0 UX1 UY1 _ <<< "$CU"
LH=$((CY1 - CY0 + 1))
[ "$UY1" -le $((CY0 + 1)) ] && [ "$UY0" -ge $((CY0 - LH - 2)) ] \
  || fail "C: Up from rows $CY0..$CY1 put the caret on rows $UY0..$UY1 -- not one line up"
[ "$(abs $((UX0 - CX0)))" -le 8 ] || fail "C: Up moved the caret from x $CX0 to x $UX0"
run_win c2 --click-after-frames "5:$CLICK_X,$CLICK_Y" --key-after-frames "10:ArrowUp:down;ArrowDown:down"
read -r DX0 DY0 _ _ _ <<< "$(caret_of c2)"
[ "$(abs $((DX0 - CX0)))" -le 1 ] && [ "$(abs $((DY0 - CY0)))" -le 1 ] \
  || fail "C: Up then Down left the caret at ($DX0,$DY0), not back at ($CX0,$CY0)"
echo "   OK: Up -> x $UX0 rows $UY0..$UY1; Down -> back at x $DX0"

echo "== D. typing past the box width wraps; the caret follows =="
SUFFIX=" november oscar papa"
CPS="$(python3 -c 'import sys; print(";".join(str(ord(c)) for c in sys.argv[1]))' "$SUFFIX")"
NCH=${#SUFFIX}
# Same input twice; the second run adds one ArrowLeft AFTER the typing (the
# key sequence is padded with bare Shift presses until the chars are done).
# Pixels BRIGHTER in run 1 than in run 2 = run 1's caret at the end.
PAD=""
for ((i = 0; i < NCH + 3; i++)); do PAD="$PAD;Shift:down"; done
run_win d1 --click-after-frames "5:200,130" --key-after-frames "10:End:down$PAD" --char-after-frames "12:$CPS"
run_win d2 --click-after-frames "5:200,130" --key-after-frames "10:End:down$PAD;ArrowLeft:down" --char-after-frames "12:$CPS"
case "$(last_change d1)" in *"$SUFFIX\"") ;; *) fail "D: the typed text did not land at the end ('$(last_change d1)')";; esac
[ "$(last_change d1)" = "$(last_change d2)" ] || fail "D: the two runs typed different text"
read -r _ NEW_BOT _ <<< "$($PX ink "$WORK/d1.ppm" $TX0 $BY0 $BX1 $BY1)"
[ "$NEW_BOT" -gt $((INK_BOT + 10)) ] \
  || fail "D: the paint did not wrap onto a new line (ink still ends at row $NEW_BOT)"
CDN="$($PX bbox "$WORK/d1.ppm" "$WORK/d2.ppm" 0 0 400 300 brighter)"
[ "$CDN" != "NONE" ] || fail "D: no caret painted after typing past the width (it ran off the edge)"
read -r EX0 EY0 EX1 EY1 _ <<< "$CDN"
[ "$EX1" -lt "$BX1" ] && [ "$EX0" -ge "$TX0" ] \
  || fail "D: caret x $EX0..$EX1 after typing is outside the box"
[ "$EY0" -gt "$AY1" ] && [ "$EY0" -le "$NEW_BOT" ] && [ "$NEW_BOT" -le $((EY1 + 2)) ] \
  || fail "D: caret rows $EY0..$EY1 are not on the NEW last line (old last line ended row $AY1, ink now ends $NEW_BOT)"
echo "   OK: new line ink to row $NEW_BOT; caret x $EX0 rows $EY0..$EY1"

echo "== E. Shift+Up from line 3: highlight follows the wrapped lines =="
run_win e --click-after-frames "5:$CLICK_X,$CLICK_Y" --key-after-frames "10:ArrowUp:down:shift"
grep -qE '^rn-impeller: selection tag=[0-9]+ anchor=([0-9]+) caret=([0-9]+)$' "$WORK/e.log" \
  || fail "E: no selection line after Shift+Up"
read -r N1 _ <<< "$($PX rows "$WORK/e-first.ppm" "$WORK/e.ppm" $BX0 $BY0 $BX1 "$UY0")"
[ "$N1" -eq 0 ] || fail "E: the highlight painted $N1 px on LINE 1 (above rows $UY0)"
L2="$($PX bbox "$WORK/e-first.ppm" "$WORK/e.ppm" $BX0 "$UY0" $BX1 $((UY1 + 1)))"
L3="$($PX bbox "$WORK/e-first.ppm" "$WORK/e.ppm" $BX0 "$CY0" $BX1 $((CY1 + 1)))"
[ "$L2" != "NONE" ] && [ "$L3" != "NONE" ] || fail "E: highlight missing on line 2 ('$L2') or line 3 ('$L3')"
read -r H2X0 _ H2X1 _ _ <<< "$L2"
read -r H3X0 _ H3X1 _ _ <<< "$L3"
read -r _ _ L2RIGHT <<< "$($PX ink "$WORK/base-first.ppm" $TX0 "$UY0" $BX1 $((UY1 + 1)))"
[ "$(abs $((H2X0 - UX0)))" -le 8 ] && [ "$H2X1" -ge $((L2RIGHT - 2)) ] \
  || fail "E: line-2 highlight x $H2X0..$H2X1 should run from the caret (x $UX0) to the line end (x $L2RIGHT)"
[ "$H3X0" -le $((TX0 + 2)) ] && [ "$(abs $((H3X1 - CX0)))" -le 8 ] \
  || fail "E: line-3 highlight x $H3X0..$H3X1 should run from the line start to the click (x $CX0)"
echo "   OK: line 2 x $H2X0..$H2X1, line 3 x $H3X0..$H3X1, line 1 untouched"

echo "MULTILINE_CARET_GATE_PASS (End, click line 3 + type, Up/Down, wrap-follow, wrapped selection)"
