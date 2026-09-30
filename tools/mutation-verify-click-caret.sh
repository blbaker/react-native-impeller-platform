#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-click-caret.sh (desktop-input-gap item 3).
#
# Each mutant puts back one click-to-caret defect, the gate rebuilds the engine
# itself, and the gate must FAIL on an assertion that names that defect.
#
#   M1  click leaves the caret at END (pre-item-3 behaviour)
#   M2  click mapping ignores the text inset (clicks land a glyph off). Only a
#       gate whose targets come from the PAINTED caret can see this: the
#       engine's own ti_glyph_x report shifts by the same amount.
#   M3  always rounds DOWN (a right-half click never lands after the glyph)
#   M4  clicking the already-focused field re-seeds the buffer (drops typing)
set -euo pipefail
cd "$(dirname "$0")/.."
SG="engine/scenegraph/SceneGraph.cpp"
FH="engine/fabric/FabricHost.cpp"

BAK="$(mktemp -d)"
cp "$SG" "$BAK/SceneGraph.cpp"
cp "$FH" "$BAK/FabricHost.cpp"
restore() { cp "$BAK/SceneGraph.cpp" "$SG"; cp "$BAK/FabricHost.cpp" "$FH"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$SG" "$FH" && fail "mutant residue already in the tree -- restore it first (git diff)"
grep -q "caretIndexForClick(target, x, y)" "$FH" \
  || fail "the fix is NOT in the tree (no caretIndexForClick call) -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-click-caret.sh > "$1" 2>&1
  local rc=$?
  set -e
  return $rc
}

mutate() {  # $1 = file, $2 = old text, $3 = new text
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "mutant anchor not found exactly once in %s: %r" % (p, old[:80])
open(p, "w").write(s.replace(old, new, 1))
PY
}

expect_killed() {  # $1 = name, $2 = log, $3 = ERE the FAIL line must carry
  if grep -q CLICK_CARET_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect in the binary"
  fi
  grep -qE "CLICK_CARET_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'CLICK_CARET_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q CLICK_CARET_GATE_PASS "$BAK/control.log" || fail "control did not print CLICK_CARET_GATE_PASS"
echo "   OK: control passes"

echo "== M1: click leaves the caret at END =="
mutate "$FH" \
'  const size_t caret = sceneGraph_->caretIndexForClick(target, x, y);' \
'  // MUTANT M1: caret stays at end
  const size_t caret = value.size();'
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "R: REAL click|A: click 30%"
restore

echo "== M2: click mapping ignores the text inset =="
mutate "$SG" \
'  const float textX = ox + kTextInputPad;' \
'  // MUTANT M2: text inset dropped from the click mapping
  const float textX = ox;'
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "R: REAL click|A: click 30%|B: a click on the RIGHT|D: after"
restore

echo "== M3: always rounds DOWN =="
mutate "$SG" \
'    const float d = std::fabs(screenX - xs[i]);
    if (d < bestD) {' \
'    // MUTANT M3: floor instead of nearest
    const float d = (xs[i] <= screenX) ? 0.0f : 1e9f;
    if (d <= bestD) {'
run_gate "$BAK/m3.log" || true
expect_killed M3 "$BAK/m3.log" "B: a click on the RIGHT"
restore

echo "== M4: clicking the focused field re-seeds the buffer =="
mutate "$FH" \
'  if (!alreadyFocused) sceneGraph_->setTextInputFocus(target);' \
'  // MUTANT M4: re-seed on every click
  sceneGraph_->setTextInputFocus(target);'
run_gate "$BAK/m4.log" || true
expect_killed M4 "$BAK/m4.log" "R: REAL click|onFocus fired"
restore

echo "MUTATION_VERIFY_CLICK_CARET_PASS: control PASS, M1-M4 each FAIL the gate"
