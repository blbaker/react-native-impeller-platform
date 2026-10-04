#!/usr/bin/env bash
# ENG-23 gate: <Text> lineHeight reaches MEASURE and PAINT, with one setter.
#
# THE BUG. Neither ImpellerTextLayoutManager (measure) nor SceneGraph (paint)
# called ImpellerParagraphStyleSetHeight, so every HostApp leading.ts value was
# ignored: a two-line body-md paragraph got the face's own ~18 pt pitch and a
# 36 pt box whether lineHeight was 16 or 32 (ENGINE-LEDGER ENG-23).
#
# THE ORACLE IS THE STYLE ITSELF. RN's lineHeight is absolute points, so at
# fontSize 16 a lineHeight of 16 and of 32 must give exactly 16 and 32 pt per
# line. Fixture: fixtures/eng23-line-height (two lines each, black on white).
#
#   A. MEASURE. node_frame heights: lh16 = 32, lh32 = 64 (+-1 pt), and
#      h(lh32) = 2 x h(lh16) within 1 pt (the ledger's acceptance probe).
#   B. PAINT. Ink-band pitch (top of line 1 -> top of line 2): lh16 = 16,
#      lh32 = 32 (+-1 pt). Measure-only fixes leave this at the face's ~18.
#   C. CONTROL. The paragraph with lineHeight unset paints at the face's own
#      pitch, which is neither 16 nor 32, so arm B can tell the cases apart.
#   D. PAINT FITS MEASURE. Every ink band of each paragraph sits inside its
#      measured box. Paint-only fixes overflow the 36 pt box at lh32.
#
# NO-NPM MODE: renders the committed prebuilt bundle with the staged binary.
# The Mac runs: RNI_BIN=<darwin rn-impeller> bash tools/ci-line-height.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "LINE_HEIGHT_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/eng23-line-height"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/eng23-line-height.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  bash "$ROOT/tools/build-fixture-bundle.sh" eng23-line-height Eng23LineHeight \
    || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

APP=Eng23LineHeight
set +e
"$ENGINE" --bundle "$BUNDLE" --app-name "$APP" --probe-banner off \
  --width 400 --height 300 --supersample-rnsvg 0 --headless \
  --screenshot "$WORK/lh.ppm" > "$WORK/lh.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { tail -20 "$WORK/lh.log" >&2; fail "headless render exited $rc"; }
n="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORK/lh.log" | tail -1)"
[ -n "$n" ] && [ "$n" -gt 0 ] || { tail -20 "$WORK/lh.log" >&2; fail "scene_nodes=${n:-none}: fixture did not mount"; }
grep -q '^rn-impeller: supersample_rnsvg=0$' "$WORK/lh.log" \
  || fail "engine did not report supersample_rnsvg=0 (flag dropped; darwin defaults to 4)"

# node_frame=Paragraph,<tag>,<x>,<y>,<w>,<h> for the paragraph whose y is $1.
frameh() { sed -n "s/^rn-impeller: node_frame=Paragraph,[0-9]*,[0-9.]*,$1\.0,[0-9.]*,\([0-9.]*\)$/\1/p" "$WORK/lh.log" | head -1; }
H16="$(frameh 10)"; H32="$(frameh 80)"; HCTL="$(frameh 180)"
[ -n "$H16" ] && [ -n "$H32" ] && [ -n "$HCTL" ] \
  || { grep node_frame=Paragraph "$WORK/lh.log" >&2 || true; fail "missing a Paragraph node_frame (y=10/80/180)"; }
py() { python3 -c "import sys; sys.exit(0 if ($1) else 1)"; }

# A runs on node_frame alone, BEFORE any pixel read: a wrong multiple can make
# one paragraph's ink spill into its neighbour's region, which would otherwise
# trip the band-count sanity check and hide which half (measure) broke.
echo "== A. measure: box height follows lineHeight =="
py "abs($H16 - 32) <= 1" || fail "A: lineHeight 16 x 2 lines measured $H16 pt, want 32: measure ignores lineHeight"
py "abs($H32 - 64) <= 1" || fail "A: lineHeight 32 x 2 lines measured $H32 pt, want 64: measure ignores lineHeight"
py "abs($H32 - 2 * $H16) <= 1" || fail "A: h(lh32)=$H32 is not 2 x h(lh16)=$H16 within 1 pt"
echo "   OK A: boxes $H16 / $H32 pt (control $HCTL)"

# Regions reach a little past each box so ink that overflows its box is seen.
python3 tools/ink-bands.py "$WORK/lh.ppm" 400 300 \
  lh16:20:4:200:76 lh32:20:76:200:176 ctl:20:176:200:262 > "$WORK/bands.txt"
sed 's/^/   /' "$WORK/bands.txt"
field() { sed -n "s/^$1 .*$2=\([^ ]*\).*/\1/p" "$WORK/bands.txt"; }

for r in lh16 lh32 ctl; do
  [ "$(field "$r" bands)" = "2" ] \
    || fail "paragraph $r painted $(field "$r" bands) ink bands, want 2 (fixture did not render two lines, or ink spilled across paragraphs)"
done
P16="$(field lh16 pitch)"; P32="$(field lh32 pitch)"; PCTL="$(field ctl pitch)"

echo "== C. control: unset lineHeight keeps the face's own pitch =="
py "abs($PCTL - 16) > 0.5 and abs($PCTL - 32) > 0.5" \
  || fail "C: the unset paragraph's pitch is $PCTL pt, equal to a fixture lineHeight; arm B cannot tell set from unset"
echo "   OK C: control pitch $PCTL pt"

echo "== B. paint: line pitch follows lineHeight =="
py "abs($P16 - 16) <= 1" || fail "B: lineHeight 16 painted a $P16 pt pitch, want 16: paint ignores lineHeight"
py "abs($P32 - 32) <= 1" || fail "B: lineHeight 32 painted a $P32 pt pitch, want 32: paint ignores lineHeight"
echo "   OK B: pitch $P16 / $P32 pt"

echo "== D. painted lines sit inside the measured box =="
check_inside() {  # $1 region  $2 box-y  $3 box-h
  local t b
  for t in $(field "$1" tops | tr , ' '); do
    py "$t >= $2 - 1" || fail "D: $1 ink starts at $t pt, above its box top $2"
  done
  for b in $(field "$1" bottoms | tr , ' '); do
    py "$b <= $2 + $3 + 1" || fail "D: $1 ink ends at $b pt, below its box bottom $(python3 -c "print($2 + $3)"): measure and paint disagree on line height"
  done
}
check_inside lh16 10 "$H16"; check_inside lh32 80 "$H32"; check_inside ctl 180 "$HCTL"
echo "   OK D: all ink inside its measured box"

echo "LINE_HEIGHT_GATE_PASS (lineHeight drives measured height and painted pitch alike)"
