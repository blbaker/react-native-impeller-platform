#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-hmr.sh (parity item 14).
#
#   M1  HMRClient.setup never called (no Fast Refresh)
#   M2  WebSocket rejects http:// (HMRClient's /hot URL): HMR never connects
#   M3  DevSettings.reload back to a no-op
#   M4  repeating timers count as pending JS work again (HMR's 20 s ping
#       stalls every waitForJsIdle; the first frame lands ~10 s late)
set -euo pipefail
cd "$(dirname "$0")/.."
RH="engine/runtime/ReactHost.cpp"
WS="engine/modules/WebSocketModule.cpp"
PM="engine/modules/PlatformModules.h"
JT="engine/runtime/JsThread.cpp"

BAK="$(mktemp -d)"
for f in "$RH" "$WS" "$PM" "$JT"; do cp "$f" "$BAK/$(basename "$f")"; done
restore() { for f in "$RH" "$WS" "$PM" "$JT"; do cp "$BAK/$(basename "$f")" "$f"; done; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$RH" "$WS" "$PM" "$JT" && fail "mutant residue already in the tree -- restore it first (git diff)"
grep -q 'callFunctionOnModule("HMRClient", "setup"' "$RH" || fail "the fix is NOT in the tree -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-hmr.sh > "$1" 2>&1
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
  if grep -q HMR_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect"
  fi
  grep -qE "HMR_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'HMR_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q HMR_GATE_PASS "$BAK/control.log" || fail "control did not print HMR_GATE_PASS"
echo "   OK: control passes"

echo "== M1: HMRClient.setup never called =="
mutate "$RH" \
'  instance_->callFunctionOnModule("HMRClient", "setup", std::move(args));' \
'  (void)args;  // MUTANT M1'
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "HMR updates do not apply"
restore

echo "== M2: WebSocket rejects http:// =="
mutate "$WS" \
'  if (scheme == "http") scheme = "ws";' \
'  // MUTANT M2: http not mapped to ws'
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "HMR updates do not apply"
restore

echo "== M3: DevSettings.reload is a no-op =="
mutate "$PM" \
'    if (reload_ && *reload_) (*reload_)(reason);' \
'    (void)reason;  // MUTANT M3'
run_gate "$BAK/m3.log" || true
expect_killed M3 "$BAK/m3.log" "reload is a no-op"
restore

echo "== M4: repeating timers block JS idle =="
mutate "$JT" \
'    if (!entry.second.repeat) return false;' \
'    (void)entry; return false;  // MUTANT M4'
run_gate "$BAK/m4.log" || true
expect_killed M4 "$BAK/m4.log" "stalled on HMR"
restore

echo "MUTATION_VERIFY_HMR_PASS: control PASS, M1-M4 each FAIL the gate"
