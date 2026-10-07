#!/usr/bin/env bash
# ENG-23 (TextInput): prove tools/ci-textinput-line-height.sh FAILS when any
# one piece of the fix is removed. Each mutant edits the live tree, rebuilds,
# runs the gate, restores.
#   M1 BuildTextInputParagraph drops ApplyLineHeight          -> B
#   M2 the TextInput prop read never records lineHeight       -> B
#   M3 TextInputLineH ignores lineHeight (centring at 1.2 em) -> E
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SG"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
restore() { cp "$BACKUP/SG" "$SG"; }
trap 'restore; eval "$BUILD_CMD" > /tmp/mvtilh-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

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
  if ! eval "$BUILD_CMD" > /tmp/mvtilh-build.log 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' /tmp/mvtilh-build.log | head -3 | sed 's/^/     /'
  elif bash tools/ci-textinput-line-height.sh > /tmp/mvtilh-gate.log 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "TI_LINE_HEIGHT_GATE_FAIL: ($2)" /tmp/mvtilh-gate.log; then
    echo "   caught: $(grep TI_LINE_HEIGHT_GATE_FAIL /tmp/mvtilh-gate.log | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep TI_LINE_HEIGHT_GATE_FAIL /tmp/mvtilh-gate.log | head -1 | sed 's/^/     /'
  fi
  restore
}

echo "MUTATION_VERIFY_TI_LINE_HEIGHT_START"

mutate "$SG" "  ApplyLineHeight(style, node.lineHeight, node.fontSize);  // ENG-23 TextInput" \
             "  (void)0;  // MUTANT M1"
run_mutant "M1 TextInput paragraph drops ApplyLineHeight" "B: "

mutate "$SG" "      node.lineHeight = (attrs.lineHeight > 0 && std::isfinite(attrs.lineHeight))" \
             "      node.lineHeight = (false && std::isfinite(attrs.lineHeight))  // MUTANT M2"
run_mutant "M2 TextInput prop read never records lineHeight" "B: "

mutate "$SG" "  return node.lineHeight > 0.0f ? node.lineHeight : node.fontSize * 1.2f;" \
             "  return node.fontSize * 1.2f;  // MUTANT M3"
run_mutant "M3 TextInputLineH ignores lineHeight" "E: "

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_TI_LINE_HEIGHT_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_TI_LINE_HEIGHT_FAIL ($PASS/$TOTAL)"
  exit 1
fi
