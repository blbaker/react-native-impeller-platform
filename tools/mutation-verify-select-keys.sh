#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-select-keys.sh (desktop-input-gap item 4a).
#
# Each mutant puts back one keyboard-selection defect, the gate rebuilds the
# engine itself, and the gate must FAIL on an assertion that names it.
#
#   M1  Shift ignored: caret moves never extend a selection
#   M2  typing with a selection inserts at the caret instead of replacing
#   M3  select-all bound to the wrong modifier for this platform
#       (linux/windows: meta instead of ctrl)
#   M4  highlight not painted
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
grep -q "KeyAction::SelectAll" "$FH" \
  || fail "the fix is NOT in the tree (no SelectAll) -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-select-keys.sh > "$1" 2>&1
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
  if grep -q SELECT_KEYS_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect in the binary"
  fi
  grep -qE "SELECT_KEYS_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'SELECT_KEYS_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q SELECT_KEYS_GATE_PASS "$BAK/control.log" || fail "control did not print SELECT_KEYS_GATE_PASS"
echo "   OK: control passes"

echo "== M1: Shift ignored =="
mutate "$FH" \
'    if (isCaretKey) dispatchKey(caretAction, 0, mods.shift);' \
'    // MUTANT M1: Shift ignored
    if (isCaretKey) dispatchKey(caretAction, 0, false);'
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "not extending a selection from a fixed anchor"
restore

echo "== M2: typing inserts instead of replacing the selection =="
mutate "$FH" \
'  if (hasSel && (action == KeyAction::InsertChar ||
                 action == KeyAction::Backspace ||' \
'  // MUTANT M2: InsertChar ignores the selection
  if (hasSel && (false ||
                 action == KeyAction::Backspace ||'
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "typing does not replace the selection"
restore

echo "== M3: select-all bound to the wrong modifier =="
mutate "$FH" \
'    const bool selectAllMod = mods.ctrl;' \
'    // MUTANT M3: wrong platform modifier for select-all
    const bool selectAllMod = mods.meta;'
run_gate "$BAK/m3.log" || true
expect_killed M3 "$BAK/m3.log" "select-all is not bound to this platform"
restore

echo "== M4: highlight not painted =="
mutate "$SG" \
'          ImpellerDisplayListBuilderDrawRect(builder, &selRect, selPaint);' \
'          // MUTANT M4: highlight not drawn
          (void)selRect;'
run_gate "$BAK/m4.log" || true
expect_killed M4 "$BAK/m4.log" "the selection is not painted"
restore

echo "MUTATION_VERIFY_SELECT_KEYS_PASS: control PASS, M1-M4 each FAIL the gate"
