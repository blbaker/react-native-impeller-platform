#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-tab-focus.sh (desktop-input-gap item 11).
#
#   M1  Shift ignored: Shift+Tab moves forward
#   M2  tabIndex -1 not honoured (the focusable prop is ignored for fields)
#   M3  no select-all when tabbing into a field
#   M4  no wrap-around (Tab on the last element stays put)
#   M5  focus ring not painted
set -euo pipefail
cd "$(dirname "$0")/.."
SG="engine/scenegraph/SceneGraph.cpp"
FH="engine/fabric/FabricHost.cpp"

BAK="$(mktemp -d)"
cp "$SG" "$BAK/SceneGraph.cpp"; cp "$FH" "$BAK/FabricHost.cpp"
restore() { cp "$BAK/SceneGraph.cpp" "$SG"; cp "$BAK/FabricHost.cpp" "$FH"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$SG" "$FH" && fail "mutant residue already in the tree -- restore it first (git diff)"
grep -q "int FabricHost::moveFocus" "$FH" \
  || fail "the fix is NOT in the tree (no moveFocus) -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-tab-focus.sh > "$1" 2>&1
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
  if grep -q TAB_FOCUS_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect in the binary"
  fi
  grep -qE "TAB_FOCUS_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'TAB_FOCUS_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q TAB_FOCUS_GATE_PASS "$BAK/control.log" || fail "control did not print TAB_FOCUS_GATE_PASS"
echo "   OK: control passes"

echo "== M1: Shift ignored =="
mutate "$FH" \
'  if (tabNav) moveFocus(!mods.shift);' \
'  if (tabNav) moveFocus(true);  // MUTANT M1'
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "Shift\+Tab does not go backwards"
restore

echo "== M2: tabIndex -1 not honoured =="
mutate "$SG" \
'      if (node.tiEditable && node.focusable) out->push_back(node.tag);' \
'      if (node.tiEditable) out->push_back(node.tag);  // MUTANT M2'
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "non-focusable field is in the Tab order"
restore

echo "== M3: no select-all on Tab focus =="
mutate "$FH" \
'    if (!value.empty()) {
      sceneGraph_->setTextInputSelection(to, value, 0, value.size());
    }' \
'    (void)value;  // MUTANT M3: caret at end, no selection'
run_gate "$BAK/m3.log" || true
expect_killed M3 "$BAK/m3.log" "no select-all on Tab focus"
restore

echo "== M4: no wrap-around =="
mutate "$FH" \
'    next = forward ? (idx + 1) % n : (idx - 1 + n) % n;' \
'    next = forward ? std::min(idx + 1, n - 1) : std::max(idx - 1, 0);  // MUTANT M4'
run_gate "$BAK/m4.log" || true
expect_killed M4 "$BAK/m4.log" "focus does not wrap"
restore

echo "== M5: focus ring not painted =="
mutate "$SG" \
'    ImpellerDisplayListBuilderDrawRect(builder, &rr, ring);' \
'    (void)rr;  // MUTANT M5'
run_gate "$BAK/m5.log" || true
expect_killed M5 "$BAK/m5.log" "the focus ring is not painted"
restore

echo "MUTATION_VERIFY_TAB_FOCUS_PASS: control PASS, M1-M5 each FAIL the gate"
