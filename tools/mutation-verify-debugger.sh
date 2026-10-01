#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-debugger.sh (parity item 24).
#
#   M1  HERMES_ENABLE_DEBUGGER not set for the Hermes CDP delegate: RN's
#       fallback stub -- every *.enable says ok, Runtime.evaluate is -32601
#       (the bug this item hit first, against a real Metro)
#   M2  no HostTarget passed to the ReactInstance: the page is listed but has
#       no runtime under it, so nothing can be evaluated
#   M3  the device socket is never opened: Metro never lists the app
#   M4  the inspector is torn down AFTER the runtime (no explicit detach in
#       ~ReactHost; ~InspectorHost runs last): quitting with DevTools still
#       attached crashes (exit 139, measured).
#
# NOT a mutant: skipping ONLY ReactInstance::unregisterFromInspector() while
# keeping the ordered shutdown. Measured harmless in this build (RN asserts
# on it in debug builds only; the HostTarget owns and frees the instance
# target either way), so no gate can see it -- it is not claimed as covered.
set -euo pipefail
cd "$(dirname "$0")/.."
RH="engine/runtime/ReactHost.cpp"
IH="engine/runtime/InspectorHost.cpp"
CM="engine/cmake/ReactCommonCore.cmake"
BAK="$(mktemp -d)"
for f in "$RH" "$IH" "$CM"; do cp "$f" "$BAK/$(basename "$f")"; done
restore() { for f in "$RH" "$IH" "$CM"; do cp "$BAK/$(basename "$f")" "$f"; done; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT
fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }
grep -q "MUTANT" "$RH" "$IH" "$CM" && fail "mutant residue already in the tree -- restore it first (git diff)"
grep -q 'inspector_ ? inspector_->hostTarget() : nullptr' "$RH" \
  || fail "the fix is NOT in the tree -- a passing gate here would be blind"

mutate() {  # $1 file, $2 old, $3 new
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "mutant anchor not found exactly once in %s: %r" % (p, old[:80])
open(p, "w").write(s.replace(old, new, 1))
PY
}
gate() { set +e; bash tools/ci-debugger.sh > "$1" 2>&1; local rc=$?; set -e; return $rc; }
expect_killed() {
  if grep -q DEBUGGER_GATE_PASS "$2"; then fail "$1 SURVIVED: the gate passed with this defect"; fi
  grep -qE "DEBUGGER_GATE_FAIL: .*($3)" "$2" || { tail -25 "$2" >&2; fail "$1 killed by the wrong assertion (want '$3')"; }
  echo "   OK: $1 killed -> $(grep -m1 DEBUGGER_GATE_FAIL "$2" | cut -c1-200)"
}

echo "== control =="
gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
echo "   OK: control passes"

echo "== M1: Hermes CDP delegate compiled as the fallback stub =="
mutate "$CM" '  PROPERTIES COMPILE_DEFINITIONS HERMES_ENABLE_DEBUGGER=1)' \
             '  PROPERTIES COMPILE_DEFINITIONS RNI_MUTANT_M1_NO_HERMES_DEBUGGER=1)'
gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "cannot run code in the app"
restore

echo "== M2: no HostTarget for the ReactInstance =="
mutate "$RH" '      /*parentInspectorTarget*/ inspector_ ? inspector_->hostTarget() : nullptr);' \
             '      /*parentInspectorTarget*/ nullptr);  // MUTANT M2'
mutate "$RH" '      inspector_->queue().runSync([this] { instance_->unregisterFromInspector(); });' \
             '      (void)0;  // MUTANT M2 (nothing registered)'
gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "cannot run code in the app|Debugger.pause never"
restore

echo "== M3: device socket never opened =="
mutate "$IH" '    packager_->connect();' '    // MUTANT M3: packager_->connect() skipped'
gate "$BAK/m3.log" || true
expect_killed M3 "$BAK/m3.log" "not listed in Metro"
restore

echo "== M4: inspector torn down after the runtime =="
mutate "$RH" '  if (inspector_) {
    if (instance_) {
      inspector_->queue().runSync([this] { instance_->unregisterFromInspector(); });
    }
    inspector_->shutdown();
  }
' '  // MUTANT M4: inspector torn down by ~InspectorHost, AFTER the runtime
'
gate "$BAK/m4.log" || true
expect_killed M4 "$BAK/m4.log" "quit with DevTools attached"
restore

echo "MUTATION_VERIFY_DEBUGGER_PASS: control PASS, M1-M4 each FAIL the gate"
