#!/usr/bin/env bash
# ENG-23: prove tools/ci-line-height.sh FAILS when any one piece of the fix is
# removed. Each mutant edits the live tree, rebuilds, runs the gate, restores.
#   M1 Paragraph paint drops ApplyLineHeight        -> arm B
#   M2 measure drops ApplyLineHeight                -> arm A
#   M3 Paragraph mount never records lineHeight     -> arm B
#   M4 the shared setter inverts the multiple       -> arm A
#   M5 the shared setter is a no-op                 -> arm A
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
TLM="engine/text/ImpellerTextLayoutManager.cpp"
LH="engine/text/LineHeight.h"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SG"; cp "$TLM" "$BACKUP/TLM"; cp "$LH" "$BACKUP/LH"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
restore() { cp "$BACKUP/SG" "$SG"; cp "$BACKUP/TLM" "$TLM"; cp "$BACKUP/LH" "$LH"; }
trap 'restore; eval "$BUILD_CMD" > /tmp/mvlh-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

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
  if ! eval "$BUILD_CMD" > /tmp/mvlh-build.log 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' /tmp/mvlh-build.log | head -3 | sed 's/^/     /'
  elif bash tools/ci-line-height.sh > /tmp/mvlh-gate.log 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "LINE_HEIGHT_GATE_FAIL: ($2)" /tmp/mvlh-gate.log; then
    echo "   caught: $(grep LINE_HEIGHT_GATE_FAIL /tmp/mvlh-gate.log | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep LINE_HEIGHT_GATE_FAIL /tmp/mvlh-gate.log | head -1 | sed 's/^/     /'
  fi
  restore
}

echo "MUTATION_VERIFY_LINE_HEIGHT_START"

mutate "$SG" "    ApplyLineHeight(style, node.lineHeight, node.fontSize);  // ENG-23" \
             "    (void)0;  // MUTANT M1"
run_mutant "M1 Paragraph paint drops ApplyLineHeight" "B"

mutate "$TLM" "    ApplyLineHeight(style, (float)attrs.lineHeight, fontSize);" \
              "    (void)0;  // MUTANT M2"
run_mutant "M2 measure drops ApplyLineHeight" "A"

mutate "$SG" "          node.lineHeight = (float)fragment.textAttributes.lineHeight;" \
             "          (void)0;  // MUTANT M3"
run_mutant "M3 Paragraph mount never records lineHeight" "B"

mutate "$LH" "  ImpellerParagraphStyleSetHeight(style, lineHeight / fontSize);" \
             "  ImpellerParagraphStyleSetHeight(style, fontSize / lineHeight);  // MUTANT M4"
run_mutant "M4 shared setter inverts the multiple" "A"

mutate "$LH" "  ImpellerParagraphStyleSetHeight(style, lineHeight / fontSize);" \
             "  (void)style;  // MUTANT M5"
run_mutant "M5 shared setter is a no-op" "A"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_LINE_HEIGHT_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_LINE_HEIGHT_FAIL ($PASS/$TOTAL)"
  exit 1
fi
