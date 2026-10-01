#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-exit-race.sh.
#
#   M1  no drain: the Scheduler is destroyed without waiting for the JS tick
#       (the shipped bug: SIGSEGV on quit in ci-click-caret)
#   M2  drain kept but the delegate is NOT nulled first (a NEW tick can enter
#       the delegate after the barrier)
set -euo pipefail
cd "$(dirname "$0")/.."
F="engine/fabric/FabricHost.cpp"
BAK="$(mktemp -d)"
cp "$F" "$BAK/FabricHost.cpp"
restore() { cp "$BAK/FabricHost.cpp" "$F"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT
fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }
grep -q "// MUTANT" "$F" && fail "mutant residue already in $F"
grep -q 'drained->set_value();' "$F" || fail "the fix is NOT in the tree -- a passing gate here would be blind"

mutate() {
  python3 - "$F" "$1" "$2" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "mutant anchor not found exactly once: %r" % old[:80]
open(p, "w").write(s.replace(old, new, 1))
PY
}
gate() { set +e; bash tools/ci-exit-race.sh > "$1" 2>&1; local rc=$?; set -e; return $rc; }
expect_killed() {
  if grep -q EXIT_RACE_GATE_PASS "$2"; then fail "$1 SURVIVED: the gate passed with this defect"; fi
  grep -qE "EXIT_RACE_GATE_FAIL: .*($3)" "$2" || { tail -20 "$2" >&2; fail "$1 killed by the wrong assertion (want '$3')"; }
  echo "   OK: $1 killed -> $(grep -m1 EXIT_RACE_GATE_FAIL "$2")"
}

echo "== control =="
gate "$BAK/control.log" || { tail -30 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
echo "   OK: control passes"

echo "== M1: no drain before ~Scheduler =="
mutate '    runtimeScheduler_->scheduleWork(
        [drained](facebook::jsi::Runtime&) { drained->set_value(); });
    if (done.wait_for(std::chrono::seconds(3)) != std::future_status::ready) {' \
       '    (void)done;  // MUTANT M1: no drain
    if (false) {'
gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "use-after-free on quit"
restore

echo "== M2: delegate not nulled before the drain =="
mutate '    runtimeScheduler_->setEventTimingDelegate(nullptr);
    auto drained' '    // MUTANT M2: delegate left installed
    auto drained'
gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "use-after-free on quit"
restore

echo "MUTATION_VERIFY_EXIT_RACE_PASS: control PASS, M1-M2 each FAIL the gate"
