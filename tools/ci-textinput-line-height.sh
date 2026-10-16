#!/usr/bin/env bash
# ENG-23 (TextInput) gate: lineHeight reaches TextInput PAINT, as it does <Text>.
#
# THE GAP. 6d71661 made <Text> lineHeight reach measure and paint, but the
# TextInput paragraph builder (BuildTextInputParagraph) never applied it: a
# multiline field painted the face's own ~18 pt pitch whether lineHeight was
# 16 or 32. Every TextInput path (paint, caret, click, selection, Up/Down)
# reads that ONE paragraph through TiGeomOf, so the fix lands in all of them.
#
# Fixture: fixtures/eng23-textinput-line-height (fontSize 16, black on white).
#   B. PAINT. Multiline ink-band pitch: lineHeight 16 -> 16, 32 -> 32 (+-1 pt).
#   C. CONTROL. The field with lineHeight unset keeps the face's own pitch,
#      which is neither 16 nor 32, so arm B can tell the cases apart.
#   D. FITS. Every multiline line's ink sits inside its field's box.
#   E. SINGLE LINE. A lineHeight-40 single-line field centres its 40 pt LINE
#      BOX in the 60 pt field (220 + 10 .. 220 + 50): all ink inside 230..270.
#      Centring on the face's 19.2 pt line while painting a 40 pt line pushes
#      the ink out of that band.
#
# NO-NPM MODE: renders the committed prebuilt bundle with the staged binary.
# The Mac runs: RNI_BIN=<darwin rn-impeller> bash tools/ci-textinput-line-height.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "TI_LINE_HEIGHT_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/eng23-textinput-line-height"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/eng23-textinput-line-height.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  bash "$ROOT/tools/build-fixture-bundle.sh" eng23-textinput-line-height Eng23TextInputLineHeight \
    || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

set +e
"$ENGINE" --bundle "$BUNDLE" --app-name Eng23TextInputLineHeight --probe-banner off \
  --width 400 --height 300 --supersample-rnsvg 0 --headless \
  --screenshot "$WORK/ti.ppm" > "$WORK/ti.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { tail -20 "$WORK/ti.log" >&2; fail "headless render exited $rc"; }
grep -q '^rn-impeller: supersample_rnsvg=0$' "$WORK/ti.log" \
  || fail "engine did not report supersample_rnsvg=0 (flag dropped; darwin defaults to 4)"
[ "$(grep -c '^rn-impeller: node_frame=TextInput,' "$WORK/ti.log")" = "4" ] \
  || { grep node_frame "$WORK/ti.log" >&2 || true; fail "want 4 TextInput node_frames: fixture did not mount"; }
py() { python3 -c "import sys; sys.exit(0 if ($1) else 1)"; }

python3 tools/ink-bands.py "$WORK/ti.ppm" 400 300 \
  lh16:20:2:260:68 lh32:20:68:260:153 ctl:20:153:260:218 one:20:218:260:282 > "$WORK/bands.txt"
sed 's/^/   /' "$WORK/bands.txt"
field() { sed -n "s/^$1 .*$2=\([^ ]*\).*/\1/p" "$WORK/bands.txt"; }

for r in lh16 lh32 ctl; do
  [ "$(field "$r" bands)" = "2" ] \
    || fail "field $r painted $(field "$r" bands) ink bands, want 2 (two lines did not render, or ink spilled across fields)"
done
[ "$(field one bands)" = "1" ] || fail "single-line field painted $(field one bands) ink bands, want 1"
P16="$(field lh16 pitch)"; P32="$(field lh32 pitch)"; PCTL="$(field ctl pitch)"

echo "== C. control: unset lineHeight keeps the face's own pitch =="
py "abs($PCTL - 16) > 0.5 and abs($PCTL - 32) > 0.5" \
  || fail "C: the unset field's pitch is $PCTL pt, equal to a fixture lineHeight; arm B cannot tell set from unset"
echo "   OK C: control pitch $PCTL pt"

echo "== B. paint: multiline TextInput line pitch follows lineHeight =="
py "abs($P16 - 16) <= 1" || fail "B: lineHeight 16 painted a $P16 pt pitch, want 16: TextInput paint ignores lineHeight"
py "abs($P32 - 32) <= 1" || fail "B: lineHeight 32 painted a $P32 pt pitch, want 32: TextInput paint ignores lineHeight"
echo "   OK B: pitch $P16 / $P32 pt"

echo "== D. multiline ink sits inside each field's box =="
check_inside() {  # $1 region  $2 box-y  $3 box-h
  local t b
  for t in $(field "$1" tops | tr , ' '); do
    py "$t >= $2 - 1" || fail "D: $1 ink starts at $t pt, above its box top $2"
  done
  for b in $(field "$1" bottoms | tr , ' '); do
    py "$b <= $2 + $3 + 1" || fail "D: $1 ink ends at $b pt, below its box bottom"
  done
}
check_inside lh16 5 60; check_inside lh32 70 80; check_inside ctl 155 60
echo "   OK D: all ink inside its box"

echo "== E. single line: the 40 pt line box is centred in the 60 pt field =="
T1="$(field one tops)"; B1="$(field one bottoms)"
py "$T1 >= 229 and $B1 <= 271" \
  || fail "E: single-line ink spans $T1..$B1 pt, outside the centred line box 230..270: centring and paint disagree on the line height"
echo "   OK E: ink $T1..$B1 inside 230..270"

echo "TI_LINE_HEIGHT_GATE_PASS (TextInput lineHeight drives painted pitch; single-line centring uses the same line height)"
