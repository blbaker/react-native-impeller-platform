#!/usr/bin/env bash
# ENG-43 gate: one mouse drag selects across several <Text selectable>.
#
# THE BUG (npm 0.8.2). The selection was one paragraph: the drag mapped the
# cursor through the PRESSED paragraph's own layout and never re-hit-tested.
# Measured on darwin 0.8.2 (the Mac's TEXT-SELECT-1 probe) and linux 0.8.2:
#   across  (P1 into P2)        copied only P1's part; P2 never highlighted
#   runs    (3 Text in a row)   copied 'Charlie ' only
#   below   (P2 into the gap)   copied 'Bravo fo': the x on the last line
#
# THE FIXTURE is the Mac's own (fixtures/eng43-text-select, app 'probe'),
# and arms A-F run the Mac's six drag specs unchanged. G-L add the shapes the
# Mac did not drag: backwards, upwards, three paragraphs, the whole screen,
# a press with no travel, and the left margin.
#
#   A within   inside P1                   a P1 prefix, no newline (unchanged)
#   B control  ONE two-line Text           crosses its own line (unchanged)
#   C across   P1 into P2                  'Alpha one two three.\nBravo...'
#                                          + highlight in BOTH boxes (a)
#   D runs     3 Text in a flattened row   'Charlie seven eight.', no newline,
#                                          highlight in all three boxes (b)
#   E nested   one Text, nested bold run   'Delta nine ten.' (unchanged)
#   F below    P2 down into empty space    'Bravo four five six.' (c), and no
#                                          highlight in CONTROL below it
#   G reverse  P2's end up into P1's start the same two paragraphs, in DOCUMENT
#                                          order, not drag order
#   H above    P2's end up into the gap    'Bravo four five six.': above the
#              above P2's first line       first line = the start (c)
#   I span3    P1 into CONTROL line 2      P2 in the middle selected WHOLE
#   J all      P1 to below everything      every paragraph, runs on one line
#   K tap      press, no travel            nothing copied, nothing painted
#   L margin   P1 into the margin left of  P1 only: left of a line = its start
#              P2
#
# Copy text is read from the engine's own `clipboard op=copy-text` line,
# written by the real Copy chord (RNI_DRAG_COPY=1). Highlight pixels are
# counted per paragraph box (tools/text-select-highlight.py), boxes from the
# engine's node_frame report. Drag points are layout numbers from the
# fixture, except the 'end of P2' press, which comes from P2's measured width
# (darwin and linux glyph widths differ).
#
# NO-NPM MODE: the committed prebuilt bundle + the staged binary. The Mac:
#   RNI_BIN=<darwin rn-impeller> bash tools/ci-text-select.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "TEXT_SELECT_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
# Absolute, from the CALLER's cwd: each run cds next to the binary.
case "$ENGINE" in /*) ;; *) ENGINE="$PWD/$ENGINE" ;; esac
cd "$ROOT"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/eng43-text-select"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/eng43-text-select.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  bash "$ROOT/tools/build-fixture-bundle.sh" eng43-text-select probe \
    || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

drag() {  # name, drag spec
  set +e
  ( cd "$(dirname "$ENGINE")" && RNI_DRAG_COPY=1 "$ENGINE" --bundle "$BUNDLE" --app-name probe \
      --headless --width 500 --height 300 --probe-banner off --drag "$2" \
      --screenshot "$WORK/$1.ppm" ) > "$WORK/$1.log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$1.log" >&2; fail "$1: run exited $rc"; }
  local n
  n="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORK/$1.log" | tail -1)"
  [ -n "$n" ] && [ "$n" -gt 0 ] || fail "$1: scene_nodes=${n:-none}, the fixture did not mount"
}
# The copied text, newlines as the log escapes them (a literal backslash-n).
copied() { sed -n 's/^rn-impeller: clipboard op=copy-text bytes=[0-9]* text=//p' "$WORK/$1.log" | tail -1; }
has_copy() { grep -q '^rn-impeller: clipboard op=copy-text' "$WORK/$1.log"; }
want_eq() {  # name, want (log-escaped)
  has_copy "$1" || fail "$1: nothing copied, want '$2'"
  [ "$(copied "$1")" = "$2" ] || fail "$1: copied '$(copied "$1")', want '$2'"
  echo "   $1: '$(copied "$1")'"
}
want_prefix() {  # name, must-start-with, must-be-a-prefix-of (both log-escaped)
  has_copy "$1" || fail "$1: nothing copied, want a string starting '$2'"
  local c; c="$(copied "$1")"
  case "$c" in "$2"*) ;; *) fail "$1: copied '$c', want it to start with '$2'" ;; esac
  case "$3" in "$c"*) ;; *) fail "$1: copied '$c', which is not a prefix of '$3'" ;; esac
  echo "   $1: '$c'"
}

P1='Alpha one two three.'
P2='Bravo four five six.'
CTL='Echo one two three.\nFoxtrot four five six.'
RUNS='Charlie seven eight.'
NEST='Delta nine ten.'

echo "== layout =="
drag within "24,32:150,32:200,32"
# node_frame=Paragraph,<tag>,<x>,<y>,<w>,<h>. The row View is layout-only, so
# Fabric flattens it: all seven paragraphs are children of the root View and
# their frames are absolute. Fail loudly if that ever changes.
frames="$(sed -n 's/^rn-impeller: node_frame=Paragraph,[0-9]*,\([0-9.]*,[0-9.]*,[0-9.]*,[0-9.]*\)$/\1/p' "$WORK/within.log")"
[ "$(echo "$frames" | grep -c .)" -eq 7 ] || fail "want 7 Paragraph frames, got: $(echo $frames)"
box() { echo "$frames" | awk -F, -v y="$1" '$2+0==y {print $1","$2","$3","$4}' | sort -t, -k1,1n; }
B_P1="$(box 20)"; B_P2="$(box 60)"; B_CTL="$(box 110)"; B_NEST="$(box 230)"
B_R=($(box 180))
[ -n "$B_P1" ] && [ -n "$B_P2" ] && [ -n "$B_CTL" ] && [ -n "$B_NEST" ] && [ "${#B_R[@]}" -eq 3 ] \
  || fail "fixture layout moved (row flattened? P1/P2/CTL/NEST at y=20/60/110/230, 3 runs at 180): $(echo $frames)"
echo "   P1 $B_P1 | P2 $B_P2 | CTL $B_CTL | runs ${B_R[*]} | nested $B_NEST"
IFS=, read -r P2X _ P2W _ <<< "$B_P2"
P2END=$(awk -v x="$P2X" -v w="$P2W" 'BEGIN{printf "%d", x + w - 1}')  # inside P2, right half of '.'
hl() {  # name -> "p1=N p2=N ctl=N r0=N r1=N r2=N nest=N"
  python3 "$ROOT/tools/text-select-highlight.py" "$WORK/$1.ppm" p1="$B_P1" p2="$B_P2" ctl="$B_CTL" \
    r0="${B_R[0]}" r1="${B_R[1]}" r2="${B_R[2]}" nest="$B_NEST"
}
px() { echo "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1==k {print $2}'; }
MIN=40  # highlight px a selected word must show; one 20 pt glyph cell is ~250

echo "== A. within (Mac spec, unchanged) =="
want_prefix within 'Alpha one two thr' "$P1"
h="$(hl within)"; echo "   highlight: $h"
[ "$(px "$h" p1)" -ge "$MIN" ] || fail "within: P1 shows no highlight ($h)"
[ "$(px "$h" p2)" -eq 0 ] || fail "within: P2 is highlighted, but the drag never left P1 ($h)"

echo "== B. control (Mac spec, unchanged) =="
drag control "24,122:150,140:200,146"
want_prefix control 'Echo one two three.\nFoxtrot four five si' "$CTL"

echo "== C. across: P1 into P2 (a) =="
drag across "24,32:150,50:200,72"
want_prefix across "$P1"'\nBravo ' "$P1"'\n'"$P2"
h="$(hl across)"; echo "   highlight: $h"
[ "$(px "$h" p1)" -ge "$MIN" ] || fail "across: P1 shows no highlight ($h)"
[ "$(px "$h" p2)" -ge "$MIN" ] || fail "across: P2 is selected but NOT highlighted ($h)"
[ "$(px "$h" ctl)" -eq 0 ] || fail "across: CONTROL is highlighted, past the drag ($h)"

echo "== D. runs: three Text in a row join with nothing (b) =="
drag runs "24,192:120,192:220,192"
want_eq runs "$RUNS"
h="$(hl runs)"; echo "   highlight: $h"
for r in r0 r1 r2; do
  [ "$(px "$h" "$r")" -ge "$MIN" ] || fail "runs: run $r shows no highlight ($h)"
done

echo "== E. nested (Mac spec, unchanged) =="
drag nested "24,242:100,242:160,242"
want_eq nested "$NEST"

echo "== F. below: a drag under P2 selects to its end (c) =="
drag below "24,72:100,90:100,100"
want_eq below "$P2"
h="$(hl below)"; echo "   highlight: $h"
[ "$(px "$h" p2)" -ge "$MIN" ] || fail "below: P2 shows no highlight ($h)"
[ "$(px "$h" ctl)" -eq 0 ] || fail "below: CONTROL is highlighted, but nothing in it is selected ($h)"

echo "== G. reverse: P2's end back up into P1's start =="
drag reverse "$P2END,72:150,50:24,32"
want_eq reverse "$P1"'\n'"$P2"

echo "== H. above: P2's end up into the gap above P2 (c) =="
drag above "$P2END,72:100,56:100,52"
want_eq above "$P2"
h="$(hl above)"; echo "   highlight: $h"
[ "$(px "$h" p1)" -eq 0 ] || fail "above: P1 is highlighted, but the drag stopped above P2 ($h)"

echo "== I. span3: P1 into CONTROL's second line selects P2 whole =="
drag span3 "24,32:150,90:100,146"
want_prefix span3 "$P1"'\n'"$P2"'\nEcho one two three.\nFox' "$P1"'\n'"$P2"'\n'"$CTL"
h="$(hl span3)"; echo "   highlight: $h"
[ "$(px "$h" p2)" -ge "$MIN" ] || fail "span3: the middle paragraph P2 shows no highlight ($h)"

echo "== J. all: P1 to below everything =="
# x=60 sits mid 'Delta': the end of NESTED comes from the below-the-last-line
# rule (c), not from the x running past the line's end.
drag all "24,32:60,280:60,295"
want_eq all "$P1"'\n'"$P2"'\n'"$CTL"'\n'"$RUNS"'\n'"$NEST"
h="$(hl all)"; echo "   highlight: $h"
for k in p1 p2 ctl r0 r1 r2 nest; do
  [ "$(px "$h" "$k")" -ge "$MIN" ] || fail "all: $k shows no highlight ($h)"
done

echo "== L. margin: P1 into the left margin beside P2 stops at P2's start =="
# A point left of a line is that line's START (as in any text view), so P2
# contributes nothing: the copy is P1 alone and P2 stays unpainted.
drag margin "24,32:10,60:5,72"
want_eq margin "$P1"
h="$(hl margin)"; echo "   highlight: $h"
[ "$(px "$h" p2)" -eq 0 ] || fail "margin: P2 is highlighted, but the drag stopped at its start ($h)"

echo "== K. tap: a press with no travel selects nothing =="
drag tap "24,32:24,32"
! has_copy tap || fail "tap: a press with no travel copied '$(copied tap)'"
h="$(hl tap)"
[ "$(px "$h" p1)" -eq 0 ] || fail "tap: a press with no travel painted a highlight ($h)"
echo "   tap: nothing copied, $h"

echo "TEXT_SELECT_GATE_PASS arms=12 engine=$ENGINE"
