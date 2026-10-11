#!/usr/bin/env bash
# ENG-16: prove tools/ci-textinput-valign.sh FAILS when any one piece of the
# fix is removed. Each mutant edits the live tree, rebuilds, runs the gate.
#   M1 multiline Auto resolves to centre (the old rule)      -> arm A
#   M2 mount never records multiline                          -> arm A
#   M3 mount never records textAlignVertical                  -> arm B|C|E
#   M4 content insets ignored (top/bottom use the frame edge) -> arm A
#   M5 bottom places ONE line, not the measured block         -> arm C
#   M6 single-line Auto resolves to top                       -> arm D
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SG"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
restore() { cp "$BACKUP/SG" "$SG"; }
trap 'restore; eval "$BUILD_CMD" > /tmp/mvva-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

PASS=0; TOTAL=0
mutate() {  # $1 file  $2 old  $3 new  (exact, must occur exactly once)
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
n = s.count(old)
assert n == 1, f"anchor found {n}x in {p}: {old[:60]!r}"
open(p, "w").write(s.replace(old, new))
PY
}
run_mutant() {  # $1 name  $2 ERE the FAIL line must match
  TOTAL=$((TOTAL + 1))
  echo "--- $1"
  if ! eval "$BUILD_CMD" > /tmp/mvva-build.log 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' /tmp/mvva-build.log | head -3 | sed 's/^/     /'
  elif bash tools/ci-textinput-valign.sh > /tmp/mvva-gate.log 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "TEXTINPUT_VALIGN_GATE_FAIL: ($2):" /tmp/mvva-gate.log; then
    echo "   caught: $(grep TEXTINPUT_VALIGN_GATE_FAIL /tmp/mvva-gate.log | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep TEXTINPUT_VALIGN_GATE_FAIL /tmp/mvva-gate.log | head -1 | sed 's/^/     /'
  fi
  restore
}

echo "MUTATION_VERIFY_TEXTINPUT_VALIGN_START"

mutate "$SG" "  if (mode == 0) mode = multiline ? 1 : 3;" \
             "  if (mode == 0) mode = 3; (void)multiline;  // MUTANT M1"
run_mutant "M1 multiline Auto centres" "A"

mutate "$SG" "      node.tiMultiline = tp->multiline;  // ENG-16" \
             "      node.tiMultiline = false;  // MUTANT M2"
run_mutant "M2 mount drops multiline" "A"

mutate "$SG" "              ? (int)*tp->paragraphAttributes.textAlignVertical
              : 0;" "              ? 0  // MUTANT M3
              : 0;"
run_mutant "M3 mount drops textAlignVertical" "B|C|E"

mutate "$SG" "  if (mode == 1) return y + insetTop;" \
             "  if (mode == 1) return y + 0.0f * insetTop;  // MUTANT M4"
run_mutant "M4 content insets ignored" "A"

mutate "$SG" "  return TextInputLineTop(y, h, blockH, (float)insets.top, (float)insets.bottom," \
             "  return TextInputLineTop(y, h, lineH, (float)insets.top, (float)insets.bottom,  // MUTANT M5"
run_mutant "M5 bottom places one line, not the block" "C"

mutate "$SG" "  if (mode == 0) mode = multiline ? 1 : 3;" \
             "  if (mode == 0) mode = multiline ? 1 : 1;  // MUTANT M6"
run_mutant "M6 single-line Auto goes to top" "D"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_TEXTINPUT_VALIGN_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_TEXTINPUT_VALIGN_FAIL ($PASS/$TOTAL)"
  exit 1
fi
