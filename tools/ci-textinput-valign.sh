#!/usr/bin/env bash
# ENG-16 gate: <TextInput> places its text vertically like iOS: a multiline
# field starts at the TOP of its content box, single-line stays centred, and
# textAlignVertical (top/center/bottom) overrides either.
#
# THE BUG. The TextInput painter centred one line in the field's height for
# every field. A Gluestack Textarea (multiline, ~100 pt tall) drew line one in
# the middle of the box: GS-0 measured the box at y 258..357 and line one at
# y 301 (ENGINE-LEDGER ENG-16).
#
# THE ORACLE IS THE LAID-OUT BOX. node_frame gives each field's y/h; the
# fixture's padding (12) is the content inset. Ink bands come from pixels.
# Fixture fixtures/eng16-textinput-valign: five fields, fontSize 16.
#
#   A. MULTILINE DEFAULT = TOP. Ink starts within [content top - 1, +6].
#      This is the ledger's acceptance probe (line one at the top of the box).
#   B. textAlignVertical center: ink midpoint within 3 pt of the box centre.
#   C. textAlignVertical bottom, two-line value: the LAST line ends within
#      [content bottom - 6, + 1], and both lines are inside the box.
#   D. CONTROL. Single-line, no prop: still centred (within 3 pt), i.e. the
#      pre-ENG-16 behaviour every single-line field relies on is unchanged.
#   E. Single-line + textAlignVertical top: ink starts within [top-1, +6].
#
# NO-NPM MODE: renders the committed prebuilt bundle with the staged binary.
# The Mac runs: RNI_BIN=<darwin rn-impeller> bash tools/ci-textinput-valign.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "TEXTINPUT_VALIGN_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/eng16-textinput-valign"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/eng16-textinput-valign.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  bash "$ROOT/tools/build-fixture-bundle.sh" eng16-textinput-valign Eng16TextAlignVertical \
    || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

set +e
"$ENGINE" --bundle "$BUNDLE" --app-name Eng16TextAlignVertical --probe-banner off \
  --width 400 --height 480 --supersample-rnsvg 0 --headless \
  --screenshot "$WORK/va.ppm" > "$WORK/va.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { tail -20 "$WORK/va.log" >&2; fail "headless render exited $rc"; }
n="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORK/va.log" | tail -1)"
[ -n "$n" ] && [ "$n" -gt 0 ] || { tail -20 "$WORK/va.log" >&2; fail "scene_nodes=${n:-none}: fixture did not mount"; }
grep -q '^rn-impeller: supersample_rnsvg=0$' "$WORK/va.log" \
  || fail "engine did not report supersample_rnsvg=0 (flag dropped; darwin defaults to 4)"

PAD=12
# node_frame=TextInput,<tag>,<x>,<y>,<w>,<h> for the field whose y is $1 -> h
frameh() { sed -n "s/^rn-impeller: node_frame=TextInput,[0-9]*,[0-9.]*,$1\.0,[0-9.]*,\([0-9.]*\)$/\1/p" "$WORK/va.log" | head -1; }
for y in 10 120 230 340 410; do
  [ -n "$(frameh $y)" ] || { grep node_frame=TextInput "$WORK/va.log" >&2 || true; fail "no TextInput node_frame at y=$y"; }
done

# Regions: the field's x span inside the padding, y from 5 pt above the box to
# 5 pt below, so ink that escapes its box is still attributed to it.
python3 tools/ink-bands.py "$WORK/va.ppm" 400 480 \
  mauto:24:5:316:115 mcen:24:115:316:225 mbot:24:225:316:335 \
  sauto:24:335:316:405 stop:24:405:316:475 > "$WORK/bands.txt"
sed 's/^/   /' "$WORK/bands.txt"
field() { sed -n "s/^$1 .*$2=\([^ ]*\).*/\1/p" "$WORK/bands.txt"; }
first() { field "$1" "$2" | cut -d, -f1; }
last() { field "$1" "$2" | tr , '\n' | tail -1; }
py() { python3 -c "import sys; sys.exit(0 if ($1) else 1)"; }
for r in mauto mcen mbot sauto stop; do
  [ "$(field "$r" bands)" != "0" ] || fail "field $r painted no ink"
done
[ "$(field mbot bands)" = "2" ] || fail "C: the two-line bottom field painted $(field mbot bands) ink bands, want 2"

echo "== A. multiline default starts at the top of the content box =="
T="$(first mauto tops)"; CT=$((10 + PAD))
py "$CT - 1 <= $T <= $CT + 6" \
  || fail "A: multiline field (box y 10..110, content top $CT) starts its ink at y $T: line one is not at the top"
echo "   OK A: ink top $T (content top $CT)"

echo "== B. textAlignVertical center =="
MID="$(python3 -c "print(($(first mcen tops) + $(last mcen bottoms)) / 2)")"
py "abs($MID - 170) <= 3" || fail "B: centred multiline ink midpoint $MID, want 170 +- 3"
echo "   OK B: ink midpoint $MID (box centre 170)"

echo "== C. textAlignVertical bottom (two-line value) =="
B="$(last mbot bottoms)"; T2="$(first mbot tops)"; CB=$((230 + 100 - PAD))
py "$CB - 6 <= $B <= $CB + 1" \
  || fail "C: bottom-aligned field's last line ends at y $B, want within [$((CB - 6)), $((CB + 1))] (content bottom $CB)"
py "$T2 >= 230 + $PAD - 1" || fail "C: bottom-aligned block starts at y $T2, above its content box"
echo "   OK C: last line ends at $B (content bottom $CB), block starts $T2"

echo "== D. control: single-line default stays centred =="
MID="$(python3 -c "print(($(first sauto tops) + $(last sauto bottoms)) / 2)")"
py "abs($MID - 370) <= 3" \
  || fail "D: single-line default ink midpoint $MID, want 370 +- 3: the single-line placement changed"
echo "   OK D: ink midpoint $MID (box centre 370)"

echo "== E. single-line textAlignVertical top =="
T="$(first stop tops)"; CT=$((410 + PAD))
py "$CT - 1 <= $T <= $CT + 6" \
  || fail "E: single-line top-aligned field starts its ink at y $T, want within [$((CT - 1)), $((CT + 6))]"
echo "   OK E: ink top $T (content top $CT)"

echo "TEXTINPUT_VALIGN_GATE_PASS (multiline starts at the top; textAlignVertical top/center/bottom honoured; single-line unchanged)"
