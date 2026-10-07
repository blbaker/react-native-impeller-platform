#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-multiline-caret.sh (ENG-25).
#
# Each mutant puts back one way a multiline field's caret / hit test /
# selection / Up-Down can disagree with the wrapped paint. The engine is
# rebuilt, the gate runs, and it must FAIL on the arm that names the defect.
#
#   M1 caret paints from the UNWRAPPED prefix (the shipped bug)   -> A
#   M2 click ignores y: every click lands on line 1 (the bug)      -> B
#   M3 Up/Down in SceneGraph is a no-op                            -> C
#   M4 selection highlight is one unwrapped rect on line 1         -> E
#   M5 hit test lays out at a different width than paint          -> B
#   M6 FabricHost never routes ArrowUp/Down for multiline          -> C
#   M7 caret x right but painted on line 1's row                   -> A
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
FH="engine/fabric/FabricHost.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SG"
cp "$FH" "$BACKUP/FH"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
if [ -z "${GATE_CMD:-}" ]; then
  if [ -z "${DISPLAY:-}" ] && command -v xvfb-run > /dev/null; then
    GATE_CMD="xvfb-run -a -s '-screen 0 1280x1024x24' bash tools/ci-multiline-caret.sh"
  else
    GATE_CMD="bash tools/ci-multiline-caret.sh"
  fi
fi
LOGS="${MUT_LOGS:-/tmp/mvmc}"
mkdir -p "$LOGS"
restore() { cp "$BACKUP/SG" "$SG"; cp "$BACKUP/FH" "$FH"; }
trap 'restore; eval "$BUILD_CMD" > "$LOGS/restore.log" 2>&1 || true; rm -rf "$BACKUP"' EXIT

grep -q "MUTANT" "$SG" "$FH" && { echo "mutant residue already in the tree -- restore it first (git diff)" >&2; exit 1; }

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
run_mutant() {  # $1 name  $2 ERE the FAIL line must match (arm letter)
  TOTAL=$((TOTAL + 1))
  local tag="${1%% *}"
  echo "--- $1"
  if ! eval "$BUILD_CMD" > "$LOGS/$tag-build.log" 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' "$LOGS/$tag-build.log" | head -3 | sed 's/^/     /'
  elif eval "$GATE_CMD" > "$LOGS/$tag-gate.log" 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "MULTILINE_CARET_GATE_FAIL: ($2):" "$LOGS/$tag-gate.log"; then
    echo "   caught: $(grep MULTILINE_CARET_GATE_FAIL "$LOGS/$tag-gate.log" | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep MULTILINE_CARET_GATE_FAIL "$LOGS/$tag-gate.log" | head -1 | sed 's/^/     /'
  fi
  restore
}

echo "MUTATION_VERIFY_MULTILINE_CARET_START"

if [ "${SKIP_CONTROL:-0}" != "1" ]; then
  echo "--- control: unmutated tree must PASS"
  eval "$BUILD_CMD" > "$LOGS/control-build.log" 2>&1 || { echo "control build failed" >&2; exit 1; }
  eval "$GATE_CMD" > "$LOGS/control-gate.log" 2>&1 \
    || { tail -20 "$LOGS/control-gate.log" >&2; echo "MUTATION_VERIFY_MULTILINE_CARET_FAIL: control fails" >&2; exit 1; }
  echo "   OK: control passes"
fi

mutate "$SG" "        if (wrapped) {
          // ENG-25: the caret's wrapped line and x in the painted layout." \
"        if (false) {  // MUTANT M1
          // ENG-25: the caret's wrapped line and x in the painted layout."
run_mutant "M1 caret paints from the unwrapped prefix" "A"

mutate "$SG" "        if (screenY < g.textY + g.lines[i].top + g.lines[i].height) {" \
             "        if (true) {  // MUTANT M2"
run_mutant "M2 click ignores y (line 1 always)" "B"

mutate "$SG" "  if (dir < 0 && L == 0) return 0;" \
             "  return caret;  // MUTANT M3
  if (dir < 0 && L == 0) return 0;"
run_mutant "M3 vertical move is a no-op" "C"

mutate "$SG" "          if (wrapped) {
            // ENG-25: one rect per wrapped line" \
"          if (false) {  // MUTANT M4
            // ENG-25: one rect per wrapped line"
run_mutant "M4 selection is one unwrapped rect" "E"

mutate "$SG" "      shown.empty() ? nullptr : BuildTextInputParagraph(typo, node, shown, w, nullptr);" \
             "      shown.empty() ? nullptr : BuildTextInputParagraph(typo, node, shown, w + 80.0f, nullptr);  // MUTANT M5"
run_mutant "M5 hit test wraps at a different width" "B|C"

mutate "$FH" "      caretAction = key == \"ArrowUp\" ? KeyAction::MoveUp : KeyAction::MoveDown;" \
             "      isCaretKey = false;  // MUTANT M6"
run_mutant "M6 ArrowUp/Down never routed" "C"

mutate "$SG" "          caretTop = ty + lines[L].top;" \
             "          caretTop = ty;  // MUTANT M7"
run_mutant "M7 caret painted on line 1's row" "A"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_MULTILINE_CARET_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_MULTILINE_CARET_FAIL ($PASS/$TOTAL)"
  exit 1
fi
