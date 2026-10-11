#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-metro-logs.sh (parity item 15).
#
# The chain under test: RN's console polyfill (item 10: nativeLoggingHook ->
# console._isPolyfilled) -> setUpDeveloperTools wraps console.* to call
# HMRClient.log -> the HMR socket (items 12 + 14) -> Metro prints it.
#
#   M1  the engine's own console instead of RN's polyfill (pre-item-10):
#       console._isPolyfilled is false, so setUpDeveloperTools never wraps
#       console.* and nothing reaches Metro
#   M2  HMRClient.setup never called (pre-item-14): HMRClient buffers logs
#       forever (pendingLogs) and never sends them
set -euo pipefail
cd "$(dirname "$0")/.."
RH="engine/runtime/ReactHost.cpp"
BAK="$(mktemp -d)"
cp "$RH" "$BAK/ReactHost.cpp"
restore() { cp "$BAK/ReactHost.cpp" "$RH"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT
fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }
grep -q "// MUTANT" "$RH" && fail "mutant residue already in $RH"
grep -q 'runtime.global().setProperty(runtime, "nativeLoggingHook", hook);' "$RH" \
  || fail "item 10's nativeLoggingHook is NOT in the tree -- a passing gate here would be blind"
grep -q 'callFunctionOnModule("HMRClient", "setup"' "$RH" \
  || fail "item 14's HMRClient.setup is NOT in the tree -- a passing gate here would be blind"

mutate() {
  python3 - "$RH" "$1" "$2" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "mutant anchor not found exactly once: %r" % old[:80]
open(p, "w").write(s.replace(old, new, 1))
PY
}
gate() { set +e; bash tools/ci-metro-logs.sh > "$1" 2>&1; local rc=$?; set -e; return $rc; }
expect_killed() {
  if grep -q METROLOGS_GATE_PASS "$2"; then fail "$1 SURVIVED: the gate passed with this defect"; fi
  grep -qE "METROLOGS_GATE_FAIL: .*($3)" "$2" || { tail -20 "$2" >&2; fail "$1 killed by the wrong assertion (want '$3')"; }
  echo "   OK: $1 killed -> $(grep -m1 METROLOGS_GATE_FAIL "$2")"
}

echo "== control =="
gate "$BAK/control.log" || { tail -30 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
echo "   OK: control passes"

echo "== M1: RN's console polyfill not installed =="
mutate '  runtime.global().setProperty(runtime, "nativeLoggingHook", hook);' \
'  runtime.global().setProperty(runtime, "rniLogHookUnused", hook);  // MUTANT M1
  runtime.global().setProperty(runtime, "nativeLoggingHook", jsi::Value::undefined());'
mutate '  var hook = g.nativeLoggingHook;' '  var hook = g.rniLogHookUnused;'
gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "client logs are not forwarded"
restore

echo "== M2: HMRClient.setup never called =="
mutate '  instance_->callFunctionOnModule("HMRClient", "setup", std::move(args));' \
       '  (void)args;  // MUTANT M2'
gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "client logs are not forwarded"
restore

echo "MUTATION_VERIFY_METROLOGS_PASS: control PASS, M1-M2 each FAIL the gate"
