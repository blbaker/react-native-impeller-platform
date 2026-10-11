#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-opacity.sh (parity item 8).
#
#   M1  pre-fix behaviour: no group layer; opacity applied per draw only
#       (a child under an opacity:0 parent paints solid red)
#   M2  layer opened but the node's own draws ALSO keep their alpha
#       (opacity applied twice)
set -euo pipefail
cd "$(dirname "$0")/.."
SG="engine/scenegraph/SceneGraph.cpp"

BAK="$(mktemp -d)"
cp "$SG" "$BAK/SceneGraph.cpp"
restore() { cp "$BAK/SceneGraph.cpp" "$SG"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$SG" && fail "mutant residue already in the tree -- restore it first (git diff)"
grep -q "bool UsesOpacityLayer" "$SG" \
  || fail "the fix is NOT in the tree (no UsesOpacityLayer) -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-opacity.sh > "$1" 2>&1
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
  if grep -q OPACITY_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect in the binary"
  fi
  grep -qE "OPACITY_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'OPACITY_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q OPACITY_GATE_PASS "$BAK/control.log" || fail "control did not print OPACITY_GATE_PASS"
echo "   OK: control passes"

echo "== M1: pre-fix (no group layer, per-draw alpha only) =="
mutate "$SG" \
'bool UsesOpacityLayer(const SceneNode& n) {
  return n.opacity < 0.999f && !n.children.empty();
}' \
'bool UsesOpacityLayer(const SceneNode& n) {
  (void)n; return false;  // MUTANT M1
}'
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "parent opacity does not apply to children"
restore

echo "== M2: opacity applied twice (layer + own alpha) =="
mutate "$SG" \
'float OwnAlpha(const SceneNode& n) {
  return UsesOpacityLayer(n) ? 1.0f : n.opacity;
}' \
'float OwnAlpha(const SceneNode& n) {
  return n.opacity;  // MUTANT M2
}'
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "opacity is applied twice"
restore

echo "MUTATION_VERIFY_OPACITY_PASS: control PASS, M1-M2 each FAIL the gate"
