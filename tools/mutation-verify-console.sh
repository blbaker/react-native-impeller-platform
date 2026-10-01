#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-console.sh (parity item 10).
#
#   M1  nativeLoggingHook not installed (RN's polyfill never builds the full
#       console; only the engine fallback runs)
# (Only one mutant: a release bundle's polyfill REPLACES the fallback console
# object, so the fallback's "stay silent" guard is only reachable from a
# __DEV__ bundle, which does not boot yet (parity item 12). Its mutant is
# added with item 12.)
set -euo pipefail
cd "$(dirname "$0")/.."
RH="engine/runtime/ReactHost.cpp"

BAK="$(mktemp -d)"
cp "$RH" "$BAK/ReactHost.cpp"
restore() { cp "$BAK/ReactHost.cpp" "$RH"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$RH" && fail "mutant residue already in the tree -- restore it first (git diff)"
grep -q 'setProperty(runtime, "nativeLoggingHook", hook)' "$RH" \
  || fail "the fix is NOT in the tree -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-console.sh > "$1" 2>&1
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
  if grep -q CONSOLE_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect in the binary"
  fi
  grep -qE "CONSOLE_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'CONSOLE_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q CONSOLE_GATE_PASS "$BAK/control.log" || fail "control did not print CONSOLE_GATE_PASS"
echo "   OK: control passes"

echo "== M1: nativeLoggingHook not installed =="
mutate "$RH" \
'  runtime.global().setProperty(runtime, "nativeLoggingHook", hook);' \
'  runtime.global().setProperty(runtime, "rniLogHookUnused", hook);  // MUTANT M1
  runtime.global().setProperty(runtime, "nativeLoggingHook", jsi::Value::undefined());'
mutate "$RH" \
'  var hook = g.nativeLoggingHook;' \
'  var hook = g.rniLogHookUnused;'
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "RN's console polyfill is not installed|the polyfill is not installed"
restore

echo "MUTATION_VERIFY_CONSOLE_PASS: control PASS, M1 FAILS the gate"
