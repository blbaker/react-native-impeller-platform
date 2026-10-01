#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-metro-url.sh (parity item 13).
#
#   M1  URL bundles rejected (pre-fix: --bundle must be an absolute path)
#   M2  the bundle runs with a file:// source URL even when it came from
#       Metro (getDevServer().bundleLoadedFromServer false; HMR has no origin)
set -euo pipefail
cd "$(dirname "$0")/.."
MAIN="engine/host/main.cpp"

BAK="$(mktemp -d)"
cp "$MAIN" "$BAK/main.cpp"
restore() { cp "$BAK/main.cpp" "$MAIN"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$MAIN" && fail "mutant residue already in the tree -- restore it first (git diff)"
grep -q 'printf("rn-impeller: bundle_fetch url=%s' "$MAIN" || fail "the fix is NOT in the tree -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-metro-url.sh > "$1" 2>&1
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
  if grep -q METRO_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect"
  fi
  grep -qE "METRO_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'METRO_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q METRO_GATE_PASS "$BAK/control.log" || fail "control did not print METRO_GATE_PASS"
echo "   OK: control passes"

echo "== M1: URL bundles rejected =="
mutate "$MAIN" \
'  const bool bundleIsUrl = bundlePath.rfind("http://", 0) == 0 ||
                           bundlePath.rfind("https://", 0) == 0;' \
'  const bool bundleIsUrl = false;  // MUTANT M1'
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "does not accept a Metro URL"
restore

echo "== M2: file:// source URL for a Metro bundle =="
mutate "$MAIN" \
'      bundleIsUrl ? bundlePath : "file://" + bundlePath;' \
'      "file://" + bundlePath;  // MUTANT M2'
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "the script URL is not the Metro URL"
restore

echo "MUTATION_VERIFY_METRO_PASS: control PASS, M1-M2 each FAIL the gate"
