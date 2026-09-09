#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-window-input.sh.
#
# ⛔ WHY THIS FILE EXISTS. ci-window-input.sh was written AFTER the fix, so it
# has never been observed to fail. Worse, the OBVIOUS version of this gate —
# drive the in-process --click-after-frames hook and assert a tag came back —
# passes with glfwSetMouseButtonCallback deleted, because that hook calls the
# handler directly. It would be green on the exact bug the gate exists for.
#
# Each mutant below removes one specific property, and each must be killed by
# the assertion aimed at it. A mutant killed by the wrong assertion is not
# evidence that assertion works.
#
# M1 — delete the glfwSetMouseButtonCallback registration.
#      The pre-fix state exactly. Only the REAL XTest click can see this;
#      assertions B/C/D still pass. Must die on touch_downs=0 in assert A.
# M2 — the callback fires but never calls dispatchTouch (host handler is a
#      no-op that still counts the down). "Wired but inert" — the shape the
#      whole commission is about. Must die on touch_hits/alerts, NOT on
#      touch_downs.
# M3 — the cursor conversion is the identity (screen coords passed straight
#      through). INVISIBLE at 1x: assertions A, B and C all still pass. Must
#      die on assert D, the --scale 2 case. This is the factor-of-two that
#      lands on the wrong element on a Retina Mac.
# M4 — the conversion multiplies by pointScale instead of dividing. The
#      classic sign error. Must also die on assert D.
# M5 — the conversion reads the scale DERIVED from the framebuffer instead of
#      the effective one the surface was given, so an explicit --scale is
#      ignored. This is the mutant that models the macOS tester's hypothesis
#      for the darwin failure. It is INVISIBLE to every absolute-coordinate
#      assertion on a 1x host (fb/win == 1 makes derived == 1 and the answer
#      is the identity either way) and equally invisible to a Retina host with
#      no override. Only the D2 --scale 2 vs --scale 4 RATIO can see it: with
#      the override ignored, both runs answer the same and the ratio is 1:1.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC_MAIN="engine/host/main.cpp"
SRC_SURF="engine/host/GlfwSurface.cpp"
SRC_PS="engine/host/PointScale.h"

BAK="$(mktemp -d)"
cp "$SRC_MAIN" "$BAK/main.cpp"
cp "$SRC_SURF" "$BAK/GlfwSurface.cpp"
cp "$SRC_PS" "$BAK/PointScale.h"
restore() {
  cp "$BAK/main.cpp" "$SRC_MAIN"
  cp "$BAK/GlfwSurface.cpp" "$SRC_SURF"
  cp "$BAK/PointScale.h" "$SRC_PS"
}
trap 'restore; rm -rf "$BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

# ⚠️ MUTANT RESIDUE PRE-FLIGHT. A crashed harness leaves a mutant in the tree
# and its trap does not run on a hard failure; a later unrelated gate then
# "fails" mysteriously. Cheaper to refuse to start.
for marker in "M2: inert" "M3: identity" "M4: sign" "M5: derived"; do
  if grep -rq "$marker" "$SRC_MAIN" "$SRC_SURF" "$SRC_PS"; then
    fail "mutant residue '$marker' is already in the tree — restore it before running (git diff)"
  fi
done
grep -q "glfwSetMouseButtonCallback" "$SRC_SURF" \
  || fail "the fix is NOT PRESENT in the tree (no glfwSetMouseButtonCallback) — a passing gate here would be blind"

# ⚠️ THE EXIT STATUS MUST COME FROM THE GATE, NOT FROM A PIPE.
# `bash gate.sh | tail` reports tail's status, which is always 0 — the classic
# way a harness reports every mutant as killed while measuring nothing.
run_gate() {
  local log="$1"
  set +e
  DISPLAY="${DISPLAY:-:0}" bash tools/ci-window-input.sh > "$log" 2>&1
  local rc=$?
  set -e
  return $rc
}

echo "== control: unmutated tree must PASS =="
if ! run_gate "$BAK/control.log"; then
  tail -25 "$BAK/control.log" >&2
  fail "the gate does not pass on the UNMUTATED tree — nothing below means anything"
fi
grep -q WINDOW_INPUT_GATE_PASS "$BAK/control.log" \
  || fail "control did not print WINDOW_INPUT_GATE_PASS (a PARTIAL run cannot verify M1 — it skips the real-click assertion)"
echo "   OK: control passes with the real-click assertion live"

echo "== M1: delete the glfwSetMouseButtonCallback registration =="
python3 - "$SRC_SURF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
CALL = "  glfwSetMouseButtonCallback(window_,"
start = s.index(CALL)
end = s.index("  });", start) + len("  });\n")
mutated = s[:start] + s[end:]
# ⚠️ ASSERT ON THE CALL, NOT THE IDENTIFIER. The comment block above the
# registration NAMES glfwSetMouseButtonCallback (it explains that the symbol
# was measured at zero occurrences before the fix), so a bare
# `"glfwSetMouseButtonCallback" not in mutated` check fails on the prose and
# aborts the harness with the registration correctly removed.
assert CALL not in mutated, "M1 did not remove the registration"
open(p, "w").write(mutated)
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M1 tree did not build"
if run_gate "$BAK/m1.log"; then
  fail "M1 SURVIVED: the gate passes with the mouse-button callback deleted. It is exercising only the in-process hook, which is the pre-fix bug."
fi
grep -q 'touch_downs=0' "$BAK/m1.log" || {
  tail -25 "$BAK/m1.log" >&2
  fail "M1 was killed, but NOT by the assertion meant to catch it (touch_downs=0 from the REAL click). See the tail above for what actually failed."
}
echo "   OK: M1 killed (real click -> touch_downs=0)"
cp "$BAK/GlfwSurface.cpp" "$SRC_SURF"

echo "== M2: the click is received but never dispatched (wired but inert) =="
python3 - "$SRC_MAIN" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """    const int hit = fabric.dispatchTouch(phase, x, y);"""
new = """    // M2: inert — the callback fires and the counter moves, but no touch is
    // ever dispatched. Exactly the "handler wired, nothing happens" shape.
    (void)phase;
    const int hit = 0;"""
assert old in s, "M2 anchor not found - the handler shape changed"
open(p, "w").write(s.replace(old, new))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M2 tree did not build"
if run_gate "$BAK/m2.log"; then
  fail "M2 SURVIVED: the gate passes when clicks arrive and dispatch nothing. It is counting callbacks, not presses."
fi
# Must NOT be killed by touch_downs: the callback still fires here. Being
# killed by the wrong assertion would mean assert A cannot separate "no
# callback" from "callback does nothing", which is the distinction the two
# counters exist to draw.
grep -q 'touch_downs=0' "$BAK/m2.log" && {
  tail -25 "$BAK/m2.log" >&2
  fail "M2 was killed by the touch_downs assertion, but the callback DOES fire in M2. The gate cannot distinguish an unregistered callback from an inert one."
}
echo "   OK: M2 killed (clicks delivered, nothing dispatched)"
cp "$BAK/main.cpp" "$SRC_MAIN"

echo "== M3: the cursor conversion becomes the identity =="
python3 - "$SRC_PS" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """  const double points = cursorScreen * deviceRatio / (double)pointScale;"""
new = """  // M3: identity — treats a screen coordinate as if it were already a layout
  // point. Correct at 1x and on a derived-scale retina window; WRONG whenever
  // the layout scale differs from the device ratio.
  const double points = cursorScreen;"""
assert old in s, "M3 anchor not found - the conversion changed"
open(p, "w").write(s.replace(old, new))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M3 tree did not build"
if run_gate "$BAK/m3.log"; then
  fail "M3 SURVIVED: the gate passes with the coordinate conversion replaced by the identity. Every click assertion on a 1x host is blind to this; only the --scale case can see it."
fi
# ⛔ ATTRIBUTE ON THE RATIO ASSERTION, NOT ON A LITERAL COORDINATE.
# This used to grep for `expected '100.0,50.0'`, the 1x-host answer that assert
# D hardcoded. That literal is gone: the absolute number is host-dependent
# (it is 200.0,100.0 on a Retina Mac for the SAME correct code), which is what
# made the gate fail on darwin. Attribution now matches assert D's D2 ratio
# message, which reads identically on every display.
grep -q 'ratio must be exactly 2:1' "$BAK/m3.log" || grep -q 'CURSORPOINTS' "$BAK/m3.log" || {
  tail -25 "$BAK/m3.log" >&2
  fail "M3 was killed, but not by the scale-conversion assertion (assert D). See the tail above."
}
echo "   OK: M3 killed (scale conversion assertion)"
cp "$BAK/PointScale.h" "$SRC_PS"

echo "== M4: the conversion multiplies where it should divide =="
python3 - "$SRC_PS" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """  const double points = cursorScreen * deviceRatio / (double)pointScale;"""
new = """  // M4: sign — multiplies by the layout scale instead of dividing. The
  // classic factor-of-two, which on a retina Mac hits the wrong element.
  const double points = cursorScreen * deviceRatio * (double)pointScale;"""
assert old in s, "M4 anchor not found - the conversion changed"
open(p, "w").write(s.replace(old, new))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M4 tree did not build"
if run_gate "$BAK/m4.log"; then
  fail "M4 SURVIVED: the gate passes with the scale factor inverted."
fi
echo "   OK: M4 killed"
cp "$BAK/PointScale.h" "$SRC_PS"

echo "== M5: the conversion ignores --scale and uses the derived scale =="
# ⛔ THE MUTANT THAT MODELS THE DARWIN HYPOTHESIS.
# the macOS tester's reading of the darwin failure was that the division does
# not use the OVERRIDDEN scale. That turned out not to be what happened (the
# gate's expected value was wrong, not the engine) — but the hypothesis names
# a real bug that nothing in this harness covered, so it becomes a mutant.
# Substituting fb/win for pointScale_ makes the conversion the identity in
# every configuration, so an explicit --scale is silently ignored.
python3 - "$SRC_SURF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """  const float px = CursorPointsFromScreen(screenX, fbW, winW, pointScale_);
  const float py = CursorPointsFromScreen(screenY, fbH, winH, pointScale_);"""
new = """  // M5: derived — divides by the scale derived from the framebuffer instead
  // of the effective scale the surface was given, so --scale is ignored.
  const float derivedScale = (winW > 0 && fbW > 0) ? (float)fbW / (float)winW : 1.0f;
  const float px = CursorPointsFromScreen(screenX, fbW, winW, derivedScale);
  const float py = CursorPointsFromScreen(screenY, fbH, winH, derivedScale);"""
assert old in s, "M5 anchor not found - the dispatch conversion changed"
open(p, "w").write(s.replace(old, new))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M5 tree did not build"
if run_gate "$BAK/m5.log"; then
  fail "M5 SURVIVED: the gate passes when an explicit --scale is ignored and the derived framebuffer ratio is used instead. Every ABSOLUTE-coordinate assertion is blind to this; only the --scale 2 vs --scale 4 ratio can see it."
fi
grep -q 'ratio must be exactly 2:1' "$BAK/m5.log" || {
  tail -25 "$BAK/m5.log" >&2
  fail "M5 was killed, but not by the D2 ratio assertion — that is the ONLY assertion that can distinguish an ignored --scale from an honoured one. See the tail above."
}
echo "   OK: M5 killed (D2 ratio assertion — the override is honoured)"
cp "$BAK/GlfwSurface.cpp" "$SRC_SURF"

echo "== restore + rebuild =="
restore
trap - EXIT
RESTORE_LOG="$(mktemp)"
if ! bash tools/engine-build.sh > "$RESTORE_LOG" 2>&1; then
  tail -30 "$RESTORE_LOG" >&2
  fail "restored tree did not build (log: $RESTORE_LOG)"
fi
rm -f "$RESTORE_LOG"
rm -rf "$BAK"
echo "MUTATION_VERIFY_PASS (5/5 killed: M1 no-registration, M2 inert-dispatch, M3 identity-conversion, M4 inverted-scale, M5 ignored---scale-override)"
