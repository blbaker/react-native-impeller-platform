#!/usr/bin/env bash
# Mutation check for tools/ci-first-present.sh. Each mutant reverts ONE piece
# of the first-present fix; the gate must FAIL on each, and on the assertion
# that targets it (a mutant killed by the wrong assertion proves nothing).
#   M1  windowed boot back to waitForJsIdle      -> first frame is HOME
#   M2  boot barrier back to ImmediatePriority   -> first frame is BLACK
#   M3  firstFramePresented emit deleted         -> JS never hears it
# Sources are restored on exit, whatever happens.
set -euo pipefail
cd "$(dirname "$0")/.."
MAIN=engine/host/main.cpp; RH=engine/runtime/ReactHost.cpp
BAK="$(mktemp -d)"; cp "$MAIN" "$BAK/main.cpp"; cp "$RH" "$BAK/ReactHost.cpp"
restore() {
  cp "$BAK/main.cpp" "$MAIN"; cp "$BAK/ReactHost.cpp" "$RH"
  bash tools/engine-build.sh > /dev/null 2>&1 || echo "WARN: rebuild of restored tree failed" >&2
  rm -rf "$BAK"
}
trap restore EXIT
fail() { echo "FP_MUTATION_FAIL: $*" >&2; exit 1; }

run_gate() { set +e; bash tools/ci-first-present.sh > "$1" 2>&1; local rc=$?; set -e; return $rc; }

# mutate FILE OLD NEW: exact single replacement, asserted.
mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) >= 1, f"mutation anchor not found in {p}: {old!r}"
open(p, "w").write(s.replace(old, new))
PY
}

check() {  # name, expected-failure-substring
  bash tools/engine-build.sh > /dev/null 2>&1 || fail "$1 tree did not build"
  if run_gate "$BAK/$1.log"; then fail "$1 SURVIVED: gate passed with the fix reverted"; fi
  grep -q "$2" "$BAK/$1.log" || { tail -8 "$BAK/$1.log" >&2; fail "$1 killed by the WRONG assertion (wanted: $2)"; }
  echo "   OK: $1 killed ($(grep -o 'FIRST_PRESENT_GATE_FAIL: .*' "$BAK/$1.log" | cut -c1-90))"
  cp "$BAK/main.cpp" "$MAIN"; cp "$BAK/ReactHost.cpp" "$RH"
}

echo "== control: unmutated tree must PASS =="
bash tools/engine-build.sh > /dev/null 2>&1 || fail "control tree did not build"
run_gate "$BAK/control.log" || { tail -8 "$BAK/control.log" >&2; fail "control FAILED: nothing below means anything"; }
echo "   OK: control passes"

echo "== M1: windowed boot waits for JS idle again =="
mutate "$MAIN" "host.waitForJsQueueDrained(10000)" "host.waitForJsIdle(10000)"
check M1 "first frame is HOME"

echo "== M2: boot barrier at ImmediatePriority (scheduleWork) =="
mutate "$RH" "react::SchedulerPriority::IdlePriority" "react::SchedulerPriority::ImmediatePriority"
check M2 "first frame is BLACK"

echo "== M3: firstFramePresented emit deleted =="
mutate "$MAIN" 'host.deviceEvents()->emit("firstFramePresented", payload);' '(void)payload;'
check M3 "firstFramePresented emitted 0 times"

echo "FP_MUTATION_PASS (3/3 mutants killed by their own assertion)"
