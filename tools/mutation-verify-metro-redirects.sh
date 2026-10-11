#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-metro-redirects.sh (parity item 20).
#
#   M1  no ios retry on a resolve throw (dev bundles cannot build)
#   M2  self re-export redirect removed (BackHandler default is undefined)
#   M3  feature-flags redirect removed (hover flag ignores override)
set -euo pipefail
cd "$(dirname "$0")/.."
SH="package/src/metro-shims/index.js"

BAK="$(mktemp -d)"
cp "$SH" "$BAK/index.js"
restore() { cp "$BAK/index.js" "$SH"; }
trap 'restore; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$SH" && fail "mutant residue already in the tree -- restore it first (git diff)"
grep -q "function selfReexportSibling" "$SH" \
  || fail "the fix is NOT in the tree -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-metro-redirects.sh > "$1" 2>&1
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
  if grep -q REDIRECTS_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect in the bundle"
  fi
  grep -qE "REDIRECTS_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'REDIRECTS_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q REDIRECTS_GATE_PASS "$BAK/control.log" || fail "control did not print REDIRECTS_GATE_PASS"
echo "   OK: control passes"

echo "== M1: no ios retry on a throw =="
mutate "$SH" \
'      if (platform !== '"'"'impeller'"'"') throw error;
      resolution = baseResolve(context, moduleName, '"'"'ios'"'"');' \
'      throw error;  // MUTANT M1'
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "does not resolve for impeller"
restore

echo "== M2: self re-export redirect removed =="
mutate "$SH" \
'    if (selfReexport) return {type: '"'"'sourceFile'"'"', filePath: selfReexport};' \
'    void selfReexport;  // MUTANT M2'
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "self re-export is not redirected"
restore

echo "== M3: feature-flags redirect removed =="
mutate "$SH" \
'      return {type: '"'"'sourceFile'"'"', filePath: path.join(SHIM_DIR, FEATURE_FLAGS_SHIM)};' \
'      return resolution;  // MUTANT M3'
run_gate "$BAK/m3.log" || true
expect_killed M3 "$BAK/m3.log" "ReactNativeFeatureFlags redirect is missing"
restore

echo "MUTATION_VERIFY_REDIRECTS_PASS: control PASS, M1-M3 each FAIL the gate"
