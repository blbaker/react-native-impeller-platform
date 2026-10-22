#!/usr/bin/env bash
# ENG-43: prove tools/ci-text-select.sh FAILS when any one piece of the fix is
# removed. Each mutant edits the live tree, rebuilds, runs the gate, restores.
#   M1 the drag never re-resolves (the 0.8.2 behaviour)        -> C across
#   M2 copy puts a newline between every part                  -> D runs
#   M3 no below-the-last-line rule                             -> J all
#   M4 no above-the-first-line rule                            -> F below
#   M5 only the anchor paragraph paints its highlight          -> C across (pixels)
#   M6 middle paragraphs are dropped from the selection        -> D runs (the
#      middle run) or I span3
#   M7 a backwards drag is walked as if it were forwards       -> G reverse
#   M8 no same-line rule: a point beside a line goes elsewhere -> L margin
# Not claimed: the clip clamp for ScrollView/overflow:hidden and the modal
# scope. The fixture has neither, so no mutant there could be caught.
#
# Run it detached (systemd-run --user --collect), never inside a chat turn:
# a cut-off session would leave a mutated source tree.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FH="engine/fabric/FabricHost.cpp"
SG="engine/scenegraph/SceneGraph.cpp"
TS="engine/scenegraph/SceneGraphTextSelection.cpp"
BACKUP="$(mktemp -d)"
cp "$FH" "$BACKUP/FH"; cp "$SG" "$BACKUP/SG"; cp "$TS" "$BACKUP/TS"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
LOG="${TMPDIR:-/tmp}/mvts"
# cp then touch, never cp -p: the restored file must be NEWER than the
# mutant's object, or ninja skips the rebuild and the mutant stays linked in.
restore() {
  cp "$BACKUP/FH" "$FH"; cp "$BACKUP/SG" "$SG"; cp "$BACKUP/TS" "$TS"
  touch "$FH" "$SG" "$TS"
}
trap 'restore; eval "$BUILD_CMD" > "$LOG-restore.log" 2>&1 || true; rm -rf "$BACKUP"' EXIT
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
want() { [ "${ONLY:-}" = "" ] || [[ ",$ONLY," == *",$1,"* ]]; }
run_mutant() {  # $1 name  $2 ERE the FAIL line must match
  TOTAL=$((TOTAL + 1))
  echo "--- $1"
  if ! eval "$BUILD_CMD" > "$LOG-build.log" 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' "$LOG-build.log" | head -3 | sed 's/^/     /'
  elif bash tools/ci-text-select.sh > "$LOG-gate.log" 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "TEXT_SELECT_GATE_FAIL: ($2)" "$LOG-gate.log"; then
    echo "   caught: $(grep TEXT_SELECT_GATE_FAIL "$LOG-gate.log" | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    { grep TEXT_SELECT_GATE_FAIL "$LOG-gate.log" || tail -3 "$LOG-gate.log"; } | head -3 | sed 's/^/     /'
  fi
  restore
}
echo "MUTATION_VERIFY_TEXT_SELECT_START"
if want M1; then
mutate "$FH" "    if (!sceneGraph_->textPositionAt(tag, x, y, &focusTag, &caret)) {" \
             "    if (true) {  // MUTANT M1"
run_mutant "M1 the drag never re-resolves (0.8.2)" "across:"
fi
if want M2; then
mutate "$TS" "  auto pa = nodes_.find(a.parent);" \
             "  return false;  // MUTANT M2
  auto pa = nodes_.find(a.parent);"
run_mutant "M2 copy puts a newline between every part" "runs:"
fi
if want M3; then
mutate "$SG" "  if (clampBlock && (y - oy) >= ImpellerParagraphGetHeight(par)) {" \
             "  if (false && clampBlock && (y - oy) >= ImpellerParagraphGetHeight(par)) {  // MUTANT M3"
run_mutant "M3 no below-the-last-line rule" "all:"
fi
if want M4; then
mutate "$SG" "  if (clampBlock && (y - oy) < 0.0f) {" \
             "  if (false && clampBlock && (y - oy) < 0.0f) {  // MUTANT M4"
run_mutant "M4 no above-the-first-line rule" "below:"
fi
if want M5; then
mutate "$TS" "bool SceneGraph::textSelRangeLocked(react::Tag tag, size_t* lo, size_t* hi) {" \
             "bool SceneGraph::textSelRangeLocked(react::Tag tag, size_t* lo, size_t* hi) {
  if (tag != textSelTag_) return false;  // MUTANT M5"
run_mutant "M5 only the anchor paragraph paints" "across: P2 is selected but NOT highlighted"
fi
if want M6; then
mutate "$TS" "    if (lo < hi) textSelParts_.push_back(TextSelPart{*it, lo, hi});" \
             "    if (lo < hi && (*it == firstTag || *it == lastTag)) textSelParts_.push_back(TextSelPart{*it, lo, hi});  // MUTANT M6"
run_mutant "M6 middle paragraphs dropped" "runs:|span3:"
fi
if want M7; then
mutate "$TS" "  const bool forward = ia < iff;" \
             "  const bool forward = true;  // MUTANT M7"
run_mutant "M7 a backwards drag walked forwards" "reverse:"
fi
if want M8; then
mutate "$TS" "  if (!pick) {  // (2)" \
             "  if (false) {  // MUTANT M8"
run_mutant "M8 no same-line rule" "margin:"
fi
echo
# The gate once more on the restored tree: proves the restore rebuilt clean.
restore
eval "$BUILD_CMD" > "$LOG-build.log" 2>&1 || { echo "RESTORE BUILD FAILED"; exit 1; }
bash tools/ci-text-select.sh > "$LOG-gate.log" 2>&1 \
  || { echo "RESTORED TREE FAILS THE GATE: $(grep TEXT_SELECT_GATE_FAIL "$LOG-gate.log" | head -1)"; exit 1; }
echo "restored tree: $(tail -1 "$LOG-gate.log")"
if [ "$PASS" -eq "$TOTAL" ]; then
  if [ -n "${ONLY:-}" ]; then
    echo "MUTATION_VERIFY_TEXT_SELECT_PARTIAL_PASS ($PASS/$TOTAL, ONLY=$ONLY)"
  else
    echo "MUTATION_VERIFY_TEXT_SELECT_PASS ($PASS/$TOTAL)"
  fi
else
  echo "MUTATION_VERIFY_TEXT_SELECT_FAIL ($PASS/$TOTAL)"
  exit 1
fi
