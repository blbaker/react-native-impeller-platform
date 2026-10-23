#!/usr/bin/env bash
# Mutation check for tools/ci-key-root.sh (ENG-46). Proves the gate FAILS
# when the no-focus key target or the focused-field guard is broken.
#
#   M1  no-focus target back to the surface root (the 0.8.2 bug)  -> arm A
#   M2  onKeyPress fires on any TextInput target, focused or not   -> arm C
#
# Each mutant rebuilds the linux engine, runs the gate, and must be killed by
# the arm written for it. The tree is restored (cp, which bumps the mtime so
# ninja rebuilds) and the engine rebuilt on exit; the gate runs once more on
# the restored tree to prove the restore took.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="engine/fabric/FabricHost.cpp"

BAK="$(mktemp -d)"
cp "$SRC" "$BAK/FabricHost.cpp"
restore() { cp "$BAK/FabricHost.cpp" "$SRC"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$SRC" && fail "mutant residue already in $SRC -- restore it first (git diff)"
grep -q "sceneGraph_->keyRootTag()" "$SRC" \
  || fail "the fix is NOT in the tree (no keyRootTag call) -- a passing gate here would be blind"

build() { bash tools/engine-build.sh linux x64 > "$BAK/build.log" 2>&1 || { tail -20 "$BAK/build.log" >&2; fail "engine build failed"; }; }
run_gate() {
  set +e
  bash tools/ci-key-root.sh > "$1" 2>&1
  local rc=$?
  set -e
  return $rc
}

mutate() {  # $1 = old text, $2 = new text
  python3 - "$SRC" "$1" "$2" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "mutant anchor not found exactly once: %r" % old[:80]
open(p, "w").write(s.replace(old, new))
PY
}

expect_killed() {  # $1 = name, $2 = log, $3 = ERE the FAIL line must carry
  if grep -q KEY_ROOT_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect in the binary"
  fi
  grep -qE "KEY_ROOT_GATE_FAIL: .*($3)" "$2" || {
    tail -20 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'KEY_ROOT_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
build
run_gate "$BAK/control.log" || { tail -25 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q KEY_ROOT_GATE_PASS "$BAK/control.log" || fail "control did not print KEY_ROOT_GATE_PASS"
echo "   OK: control passes"

echo "== M1: no-focus target = the surface root (0.8.2) =="
mutate "  if (target == 0) target = sceneGraph_->keyRootTag();" \
       "  if (target == 0) target = sceneGraph_->rootTag();  // MUTANT M1"
build
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "A: keyDown went to tag=1"
restore

echo "== M2: onKeyPress on an unfocused TextInput target =="
mutate "  if (phase != KeyEventPhase::Up && focusedField != 0 && target == focusedField) {" \
       "  if (phase != KeyEventPhase::Up) {  // MUTANT M2"
build
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "C: the UNFOCUSED field's onKeyPress fired"
restore

echo "== post: restored tree must PASS again =="
build
run_gate "$BAK/post.log" || { tail -25 "$BAK/post.log" >&2; fail "gate fails after restore -- a mutant may still be linked in"; }
grep -q KEY_ROOT_GATE_PASS "$BAK/post.log" || fail "post-restore run did not print KEY_ROOT_GATE_PASS"
echo "   OK: restored tree passes"
trap - EXIT
restore
echo "logs: $BAK"
echo "KEY_ROOT_MUTATION_PASS"
