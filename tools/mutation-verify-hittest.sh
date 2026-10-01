#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-hittest.sh (parity item 9).
#
#   M1  pointerEvents ignored entirely (pre-fix)
#   M2  box-none treated as auto (the overlay itself swallows clicks)
#   M3  box-only treated as auto (children stay hittable)
#   M4  transforms ignored in hit testing (pre-fix)
#   M5  translate-only inverse (scale/rotation ignored): scale:0 is hittable
set -euo pipefail
cd "$(dirname "$0")/.."
SG="engine/scenegraph/SceneGraph.cpp"

BAK="$(mktemp -d)"
cp "$SG" "$BAK/SceneGraph.cpp"
restore() { cp "$BAK/SceneGraph.cpp" "$SG"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$SG" && fail "mutant residue already in the tree -- restore it first (git diff)"
grep -q "pointerEvents='none' removes the node AND its subtree" "$SG" \
  || fail "the fix is NOT in the tree -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-hittest.sh > "$1" 2>&1
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
  if grep -q HITTEST_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect in the binary"
  fi
  grep -qE "HITTEST_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'HITTEST_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q HITTEST_GATE_PASS "$BAK/control.log" || fail "control did not print HITTEST_GATE_PASS"
echo "   OK: control passes"

echo "== M1: pointerEvents ignored =="
mutate "$SG" \
'      case react::PointerEventsMode::None: node.pointerEvents = 1; break;
      case react::PointerEventsMode::BoxNone: node.pointerEvents = 2; break;
      case react::PointerEventsMode::BoxOnly: node.pointerEvents = 3; break;
      default: node.pointerEvents = 0; break;' \
'      default: node.pointerEvents = 0; break;  // MUTANT M1'
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "pointerEvents none is ignored"
restore

echo "== M2: box-none treated as auto =="
mutate "$SG" \
'  if (node.pointerEvents == 2) return 0;' \
'  // MUTANT M2: box-none node stays hittable'
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "pointerEvents box-none is ignored"
restore

echo "== M3: box-only treated as auto =="
mutate "$SG" \
'  if (node.pointerEvents != 3) {' \
'  if (true) {  // MUTANT M3'
run_gate "$BAK/m3.log" || true
expect_killed M3 "$BAK/m3.log" "pointerEvents box-only is ignored"
restore

echo "== M4: transforms ignored =="
mutate "$SG" \
'  if (node.hasTransform) {
    const float cx = nx + w * 0.5f, cy = ny + h * 0.5f;' \
'  if (false) {  // MUTANT M4
    const float cx = nx + w * 0.5f, cy = ny + h * 0.5f;'
run_gate "$BAK/m4.log" || true
expect_killed M4 "$BAK/m4.log" "hit testing ignores transforms"
restore

echo "== M5: translate-only inverse =="
mutate "$SG" \
'    const float det = a * d - b * cc;
    if (std::fabs(det) < 1e-6f) return 0;  // degenerate (scale 0): unhittable
    const float px = x - cx - tx, py = y - cy - ty;
    x = cx + (d * px - cc * py) / det;
    y = cy + (-b * px + a * py) / det;' \
'    (void)a; (void)b; (void)cc; (void)d;  // MUTANT M5: translation only
    x = x - tx;
    y = y - ty;'
run_gate "$BAK/m5.log" || true
expect_killed M5 "$BAK/m5.log" "hit testing ignores transforms"
restore

echo "MUTATION_VERIFY_HITTEST_PASS: control PASS, M1-M5 each FAIL the gate"
