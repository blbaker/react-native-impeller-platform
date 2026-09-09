#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-resize.sh.
#
# ⛔ WHY THIS FILE EXISTS. ci-resize.sh was written AFTER the fix, so it has
# never been observed to fail. A gate that has only ever been green is not
# evidence. Worse, the obvious version of this gate (assert the resize applies
# after --resize-after-frames) passes with the entire fix deleted, because the
# resize BODY always worked — the defect was only that nothing could consume it
# while the frame loop was blocked. So each mutation below removes one specific
# property of the fix and the gate MUST go red.
#
# M1 — delete the refresh-callback registration entirely.
#      Restores the exact pre-fix behaviour. Gate must fail on painted_during.
# M2 — the refresh handler marks dirty instead of painting.
#      The trap the commission explicitly warns about: marking dirty from
#      inside the modal loop changes nothing, because the consumer is blocked.
#      Gate must fail on painted_during.
# M3 — the refresh handler paints but skips applyResizeIfDirty.
#      A frame IS produced during the stall, so painted_during passes — and the
#      gate must still fail, on the "resize applied inside the stall window"
#      assertion, because that frame carries stale geometry.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC_MAIN="engine/host/main.cpp"
SRC_SURF="engine/host/GlfwSurface.cpp"

BAK="$(mktemp -d)"
cp "$SRC_MAIN" "$BAK/main.cpp"
cp "$SRC_SURF" "$BAK/GlfwSurface.cpp"
restore() {
  cp "$BAK/main.cpp" "$SRC_MAIN"
  cp "$BAK/GlfwSurface.cpp" "$SRC_SURF"
  rm -rf "$BAK"
}
trap restore EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

# ⚠️ THE EXIT STATUS MUST COME FROM THE GATE, NOT FROM A PIPE.
# `bash ci-resize.sh | tail` reports tail's status, which is always 0 — the
# classic way a mutation harness reports every mutant as killed while actually
# measuring nothing.
run_gate() {
  local log="$1"
  set +e
  DISPLAY="${DISPLAY:-:0}" bash tools/ci-resize.sh > "$log" 2>&1
  local rc=$?
  set -e
  return $rc
}

echo "== control: unmutated tree must PASS =="
if ! run_gate "$BAK/control.log"; then
  tail -20 "$BAK/control.log" >&2
  fail "the gate does not pass on the UNMUTATED tree — nothing below means anything"
fi
grep -q RESIZE_GATE_PASS "$BAK/control.log" || fail "control run did not print RESIZE_GATE_PASS"
echo "   OK: control passes"

echo "== M1: delete the glfwSetWindowRefreshCallback registration =="
python3 - "$SRC_SURF" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
start = s.index("  glfwSetWindowRefreshCallback(window_,")
end = s.index("});", start) + len("});\n")
mutated = s[:start] + s[end:]
assert "glfwSetWindowRefreshCallback" not in mutated, "M1 did not remove the registration"
open(p, "w").write(mutated)
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M1 tree did not build"
if run_gate "$BAK/m1.log"; then
  fail "M1 SURVIVED: the gate passes with the window-refresh callback deleted. It is not testing the fix."
fi
grep -q 'painted_during=0' "$BAK/m1.log" || {
  tail -25 "$BAK/m1.log" >&2
  fail "M1 was killed, but NOT by the assertion that is supposed to catch it (painted_during). A mutant killed by the wrong assertion is not evidence that assertion works — see the tail above for what actually failed."
}
echo "   OK: M1 killed (painted_during=0)"
cp "$BAK/GlfwSurface.cpp" "$SRC_SURF"

echo "== M2: refresh handler marks dirty instead of painting =="
python3 - "$SRC_MAIN" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """  surface.setRefreshHandler([&]() {
    applyResizeIfDirty();
    paintFrame();
  });"""
new = """  surface.setRefreshHandler([&]() {
    // M2: mark-only, the exact trap the commission warns about. Applies the
    // resize state but never renders or presents, so nothing reaches the
    // screen until the blocked loop resumes.
    applyResizeIfDirty();
  });"""
assert old in s, "M2 anchor not found - the handler shape changed"
open(p, "w").write(s.replace(old, new))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M2 tree did not build"
if run_gate "$BAK/m2.log"; then
  fail "M2 SURVIVED: the gate passes when the refresh handler only bumps a counter and never paints. It is counting callbacks, not frames."
fi
echo "   OK: M2 killed"
cp "$BAK/main.cpp" "$SRC_MAIN"

echo "== M3: refresh handler paints but skips the resize body =="
python3 - "$SRC_MAIN" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """    applyResizeIfDirty();
    paintFrame();
  });"""
new = """    paintFrame();  // M3: paints STALE geometry, resize body skipped
  });"""
assert old in s, "M3 anchor not found - the handler shape changed"
open(p, "w").write(s.replace(old, new))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M3 tree did not build"
if run_gate "$BAK/m3.log"; then
  fail "M3 SURVIVED: the gate passes when the mid-drag frame carries the OLD geometry. painted_during alone is not sufficient evidence."
fi
echo "   OK: M3 killed"
cp "$BAK/main.cpp" "$SRC_MAIN"

echo "== restore + rebuild =="
restore
trap - EXIT
# ⚠️ Rebuild from a CLEAN restored tree, and keep the log. A silent
# `> /dev/null` here once reported "restored tree did not build" with no way to
# tell a real regression from a transient build-dir state, after 3/3 mutants
# had already been killed.
RESTORE_LOG="$(mktemp)"
if ! bash tools/engine-build.sh > "$RESTORE_LOG" 2>&1; then
  tail -30 "$RESTORE_LOG" >&2
  fail "restored tree did not build (log: $RESTORE_LOG)"
fi
rm -f "$RESTORE_LOG"
echo "MUTATION_VERIFY_PASS (3/3 mutants killed: M1 no-callback, M2 mark-only, M3 stale-geometry)"
