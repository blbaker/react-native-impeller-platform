#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-drag.sh.
#
# ⛔ WHY THIS FILE EXISTS. ci-drag.sh was written AFTER the fix, so it has never
# been observed to fail. A drag gate that only checked "down==up" would pass
# with NO capture at all (a 2-point press+release hit-tests the same point
# twice and agrees), and one that only checked "a move returned a tag" would
# pass on the re-hit-testing bug the whole commission is about. Each mutant
# below removes one property the gate claims to prove, and each must be killed
# by the assertion aimed at it.
#
# M1 — the captured move RE-HIT-TESTS instead of reusing the captured tag.
#      This is the exact pre-fix defect: dispatchCapturedMove resolves the
#      point like dispatchTouch does, so a move over the mid box retargets to
#      mid. Must die on assert 7 (move over mid reported the MID tag).
# M2 — beginTouchCapture never stores the tag (capture is a no-op). Then every
#      captured move/up returns 0 — the drag "drops" the instant it starts.
#      Must die on assert 6/7 (down or move tag is 0, not the top box).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC="engine/fabric/FabricHost.cpp"

BAK="$(mktemp -d)"
cp "$SRC" "$BAK/FabricHost.cpp"
restore() { cp "$BAK/FabricHost.cpp" "$SRC"; }
trap 'restore; rm -rf "$BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

# ⚠️ MUTANT RESIDUE PRE-FLIGHT. A crashed harness leaves a mutant in the tree
# and its trap does not run on a hard kill; a later unrelated gate then "fails"
# mysteriously. Cheaper to refuse to start.
for marker in "M1: re-hit-test" "M2: no-capture"; do
  if grep -q "$marker" "$SRC"; then
    fail "mutant residue '$marker' is already in the tree — restore it before running (git diff)"
  fi
done
grep -q "dispatchCapturedMove" "$SRC" \
  || fail "the fix is NOT PRESENT in the tree (no dispatchCapturedMove) — a passing gate here would be blind"

# ⚠️ THE EXIT STATUS MUST COME FROM THE GATE, NOT FROM A PIPE.
run_gate() {
  local log="$1"
  set +e
  bash tools/ci-drag.sh > "$log" 2>&1
  local rc=$?
  set -e
  return $rc
}

echo "== control: unmutated tree must PASS =="
if ! run_gate "$BAK/control.log"; then
  tail -25 "$BAK/control.log" >&2
  fail "the gate does not pass on the UNMUTATED tree — nothing below means anything"
fi
grep -q DRAG_GATE_PASS "$BAK/control.log" \
  || fail "control did not print DRAG_GATE_PASS"
echo "   OK: control passes"

echo "== M1: the captured move re-hit-tests instead of holding the captured tag =="
# Replace the body of dispatchCapturedMove so it resolves the point itself
# (exactly dispatchTouch's behaviour) rather than routing to capturedTag_.
python3 - "$SRC" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """int FabricHost::dispatchCapturedMove(float x, float y) {
  if (capturedTag_ == 0) return 0;
  return dispatchTouchToTarget(TouchPhase::Move, (react::Tag)capturedTag_, x, y);
}"""
new = """int FabricHost::dispatchCapturedMove(float x, float y) {
  if (capturedTag_ == 0) return 0;
  // M1: re-hit-test — resolve the move's own point instead of holding the
  // captured tag. This is the pre-fix defect: a move over a sibling retargets.
  return dispatchTouch(TouchPhase::Move, x, y);
}"""
assert old in s, "M1 anchor not found - dispatchCapturedMove changed"
open(p, "w").write(s.replace(old, new))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M1 tree did not build"
if run_gate "$BAK/m1.log"; then
  fail "M1 SURVIVED: the gate passes when the captured move re-hit-tests. It cannot see a drag that retargets to whatever is under the cursor — the exact bug it exists for."
fi
# Must die on the assert-7 retarget message, NOT on a build/other failure.
grep -q 'RETARGETED' "$BAK/m1.log" || {
  tail -25 "$BAK/m1.log" >&2
  fail "M1 was killed, but NOT by the retarget assertion (assert 7). A move over the mid box must report the mid tag under M1; see the tail above for what actually failed."
}
echo "   OK: M1 killed (move over mid retargeted to the mid tag)"
restore

echo "== M2: the press never stores the captured tag (capture is a no-op) =="
python3 - "$SRC" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """  const int hit = dispatchTouchToTarget(TouchPhase::Down, target, x, y);
  capturedTag_ = hit;  // 0 when the press landed on empty space / a non-touch
  return hit;"""
new = """  const int hit = dispatchTouchToTarget(TouchPhase::Down, target, x, y);
  // M2: no-capture — the Down still dispatches, but the tag is never stored, so
  // every later move/up finds capturedTag_==0 and the drag drops immediately.
  capturedTag_ = 0;
  return hit;"""
assert old in s, "M2 anchor not found - beginTouchCapture changed"
open(p, "w").write(s.replace(old, new))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M2 tree did not build"
if run_gate "$BAK/m2.log"; then
  fail "M2 SURVIVED: the gate passes when the press captures nothing. A drag that drops at the first move is invisible to it."
fi
# The captured move returns 0 with no capture, so the move line reads tag 0.
# That is neither the mid tag nor the down tag: assert 7's "not the captured
# down tag" branch kills it. Confirm it is a move/hold failure, not the build.
grep -q 'DRAG_GATE_FAIL' "$BAK/m2.log" || {
  tail -25 "$BAK/m2.log" >&2
  fail "M2 was killed, but not by a gate assertion (no DRAG_GATE_FAIL line). See the tail above."
}
grep -q 'neither retargeting nor holding\|dropped when the cursor left\|did not go to the pressed' "$BAK/m2.log" || {
  tail -25 "$BAK/m2.log" >&2
  fail "M2 was killed by the WRONG assertion — a no-capture drag must fail on a move/release holding the tag, not on the press geometry. See the tail above."
}
echo "   OK: M2 killed (capture no-op -> move/release drops the tag)"
restore

echo "== restore + rebuild =="
trap - EXIT
RESTORE_LOG="$(mktemp)"
if ! bash tools/engine-build.sh > "$RESTORE_LOG" 2>&1; then
  tail -30 "$RESTORE_LOG" >&2
  fail "restored tree did not build (log: $RESTORE_LOG)"
fi
rm -f "$RESTORE_LOG"
rm -rf "$BAK"
echo "MUTATION_VERIFY_PASS (2/2 killed: M1 re-hit-testing move, M2 no-capture press)"
