#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-view-commands.sh (parity item 7).
#
#   M1  schedulerDidDispatchCommand back to an empty stub (all commands lost)
#   M2  scrollTo ignores y (always scrolls to 0)
#   M3  the TextInputState shim removed: ref.focus()/blur() send nothing
#       (the JS half of the bug; native handling is untouched)
#   M4  setTextAndSelection ignores start/end
set -euo pipefail
cd "$(dirname "$0")/.."
FH="engine/fabric/FabricHost.cpp"
SHIMS="package/src/metro-shims/index.js"

BAK="$(mktemp -d)"
cp "$FH" "$BAK/FabricHost.cpp"; cp "$SHIMS" "$BAK/index.js"
restore() { cp "$BAK/FabricHost.cpp" "$FH"; cp "$BAK/index.js" "$SHIMS"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$FH" "$SHIMS" && fail "mutant residue already in the tree -- restore it first (git diff)"
grep -q "void FabricHost::runCommand" "$FH" \
  || fail "the fix is NOT in the tree (no runCommand) -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-view-commands.sh > "$1" 2>&1
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
  if grep -q COMMANDS_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect in the binary"
  fi
  grep -qE "COMMANDS_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'COMMANDS_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q COMMANDS_GATE_PASS "$BAK/control.log" || fail "control did not print COMMANDS_GATE_PASS"
echo "   OK: control passes"

echo "== M1: schedulerDidDispatchCommand is an empty stub again =="
mutate "$FH" \
'    if (!commandHandler_) return;
    FabricHost::ViewCommand cmd;' \
'    return;  // MUTANT M1: commands dropped
    FabricHost::ViewCommand cmd;'
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "view commands are dropped"
restore

echo "== M2: scrollTo ignores y =="
mutate "$FH" \
'    const float y = cmd.nums.size() > 1 ? (float)cmd.nums[1] : 0.0f;' \
'    const float y = 0.0f;  // MUTANT M2'
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "view commands are dropped"
restore

echo "== M3: TextInputState shim removed (JS sends no focus/blur command) =="
mutate "$SHIMS" \
"  'react-native/Libraries/Components/TextInput/TextInputState.js':
    'TextInputState.impeller.js',
};" \
"};  // MUTANT M3"
run_gate "$BAK/m3.log" || true
expect_killed M3 "$BAK/m3.log" "the focus command is dropped"
restore

echo "== M4: setTextAndSelection ignores start/end =="
mutate "$FH" \
'    if (startU16 >= 0 && endU16 >= 0) {
      anchor = Utf16UnitsToUtf8Offset(value, (size_t)startU16);' \
'    if (false) {  // MUTANT M4
      anchor = Utf16UnitsToUtf8Offset(value, (size_t)startU16);'
run_gate "$BAK/m4.log" || true
expect_killed M4 "$BAK/m4.log" "setTextAndSelection is not applied"
restore

echo "MUTATION_VERIFY_COMMANDS_PASS: control PASS, M1-M4 each FAIL the gate"
