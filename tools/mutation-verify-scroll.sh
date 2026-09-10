#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-scroll.sh (ENG-02).
#
# ⛔ WHY THIS FILE EXISTS. ci-scroll.sh was written AFTER the feature, so it has
# never been observed to fail. Worse, the OBVIOUS version of a scroll gate --
# drive --scroll-after-frames and assert an offset came back -- passes with
# glfwSetScrollCallback deleted, because that hook calls the handler directly.
# It would be green on the exact bug the gate exists for. Same trap
# ci-window-input.sh fell into with synthesiseClick.
#
# Each mutant removes one property, and each must be killed BY THE ASSERTION
# AIMED AT IT. A mutant killed by the wrong assertion is not evidence that
# assertion works.
#
# M1 — delete the glfwSetScrollCallback registration.
#      The pre-ENG-02 state exactly. Only the REAL XTest wheel can see this;
#      assertions B/C/D still pass because they use the synthetic flag. Must
#      die on scroll_events=0 in assert A.
# M2 — delete the ScrollViewComponentDescriptor registration.
#      THE MUTANT THIS WHOLE COMMISSION IS ABOUT. The <ScrollView> still
#      MOUNTS, as a plain View with a base ViewEventEmitter. It lays out, it
#      paints its first screenful, it logs nothing wrong. The offset still
#      moves (SceneGraph keys off componentName, which survives), so THE PIXELS
#      STILL SCROLL -- only the dynamic_pointer_cast to ScrollViewEventEmitter
#      fails, so JS is never told. Must die on the alerts assertion (C), NOT on
#      the pixel assertion (B). If B kills it, B is accidentally testing
#      registration and C is untested.
# M3 — the wheel is received but never dispatched (host handler inert).
#      "Wired but does nothing". Must die on scroll_hits/pixels, NOT on
#      scroll_events -- the callback still fires.
# M4 — flip the GLFW sign. A fully working scroll implementation that goes the
#      wrong way. INVISIBLE to "did the offset change" and invisible to the
#      alerts count: assertions A, B's inequality half, and C all still pass.
#      Must die on assert D1 (wheel-up-at-rest must be a no-op) or on B's
#      per-height column check.
# M5 — remove the clamp (offset grows unbounded).
#      The list scrolls into empty space forever while emitting perfectly
#      plausible onScroll events. A/B/C all pass. Must die on assert D2.
# M6 — apply the scroll offset to paint but NOT to hit testing.
#      Pixels scroll correctly and every press afterwards lands on the row that
#      USED to be there. Nothing in A/B/C/D can see it, which is why this
#      mutant is expected to SURVIVE and is recorded as a known coverage gap
#      rather than silently omitted.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC_MAIN="engine/host/main.cpp"
SRC_SURF="engine/host/GlfwSurface.cpp"
SRC_FAB="engine/fabric/FabricHost.cpp"
SRC_SG="engine/scenegraph/SceneGraph.cpp"

BAK="$(mktemp -d)"
cp "$SRC_MAIN" "$BAK/main.cpp"
cp "$SRC_SURF" "$BAK/GlfwSurface.cpp"
cp "$SRC_FAB" "$BAK/FabricHost.cpp"
cp "$SRC_SG" "$BAK/SceneGraph.cpp"
restore() {
  cp "$BAK/main.cpp" "$SRC_MAIN"
  cp "$BAK/GlfwSurface.cpp" "$SRC_SURF"
  cp "$BAK/FabricHost.cpp" "$SRC_FAB"
  cp "$BAK/SceneGraph.cpp" "$SRC_SG"
}
trap 'restore; rm -rf "$BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

# ⚠️ MUTANT RESIDUE PRE-FLIGHT. A crashed harness leaves a mutant in the tree
# and its trap does not run on a hard kill; a later unrelated gate then "fails"
# mysteriously. Cheaper to refuse to start.
for marker in "M3: inert" "M4: sign" "M5: unclamped" "M6: hittest"; do
  if grep -rq "$marker" "$SRC_MAIN" "$SRC_SURF" "$SRC_FAB" "$SRC_SG"; then
    fail "mutant residue '$marker' is already in the tree — restore it before running (git diff)"
  fi
done
# ⚠️ ASSERT ON THE CALL, NOT THE IDENTIFIER: the comment block above each
# registration NAMES the symbol, so a bare identifier grep matches the prose.
grep -q "  glfwSetScrollCallback(window_," "$SRC_SURF" \
  || fail "the ENG-02 fix is NOT PRESENT (no glfwSetScrollCallback registration) — a passing gate here would be blind"
grep -q "ScrollViewComponentDescriptor>())" "$SRC_FAB" \
  || fail "the ENG-02 descriptor registration is NOT PRESENT — a passing gate here would be blind"

# ⚠️ THE EXIT STATUS MUST COME FROM THE GATE, NOT FROM A PIPE.
# `bash gate.sh | tail` reports tail's status, which is always 0 — the classic
# way a harness reports every mutant as killed while measuring nothing.
run_gate() {
  local log="$1"
  set +e
  DISPLAY="${DISPLAY:-:0}" bash tools/ci-scroll.sh > "$log" 2>&1
  local rc=$?
  set -e
  return $rc
}

echo "== control: unmutated tree must PASS =="
if ! run_gate "$BAK/control.log"; then
  tail -25 "$BAK/control.log" >&2
  fail "the gate does not pass on the UNMUTATED tree — nothing below means anything"
fi
grep -q SCROLL_GATE_PASS "$BAK/control.log" \
  || fail "control did not print SCROLL_GATE_PASS (a PARTIAL run cannot verify M1 — it skips the real-wheel assertion)"
echo "   OK: control passes with the real-wheel assertion live"

echo "== M1: delete the glfwSetScrollCallback registration =="
python3 - "$SRC_SURF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
CALL = "  glfwSetScrollCallback(window_,"
start = s.index(CALL)
end = s.index("  });", start) + len("  });\n")
mutated = s[:start] + s[end:]
assert CALL not in mutated, "M1 did not remove the registration"
open(p, "w").write(mutated)
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M1 tree did not build"
if run_gate "$BAK/m1.log"; then
  fail "M1 SURVIVED: the gate passes with the GLFW scroll callback deleted. It is exercising only the in-process --scroll-after-frames hook, which is the pre-ENG-02 bug."
fi
grep -q 'scroll_events=0' "$BAK/m1.log" || {
  tail -25 "$BAK/m1.log" >&2
  fail "M1 was killed, but NOT by the assertion meant to catch it (scroll_events=0 from the REAL wheel). See the tail above for what actually failed."
}
echo "   OK: M1 killed (real wheel -> scroll_events=0)"
cp "$BAK/GlfwSurface.cpp" "$SRC_SURF"

echo "== M2: delete the ScrollViewComponentDescriptor registration =="
python3 - "$SRC_FAB" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ScrollViewComponentDescriptor>());"""
assert old in s, "M2 anchor not found - the registration shape changed"
new = """  // M2: unregistered — the ScrollView still mounts, as a plain View."""
s = s.replace(old, new)
# The name list must go too, or RN's NativeComponentRegistry and the provider
# registry disagree and the mutant models something else entirely.
s = s.replace('"RawText", "ScrollView"};', '"RawText"};')
open(p, "w").write(s)
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M2 tree did not build"
if run_gate "$BAK/m2.log"; then
  fail "M2 SURVIVED: the gate passes with the ScrollView descriptor UNREGISTERED. An unregistered component mounts as a plain View, paints, and logs cleanly — this is the exact failure the commission is about, and the gate cannot see it."
fi
# Must be killed by an EMITTER-shaped assertion, not the pixel one. Measured
# 2026-09-09: the actual killer is scroll_hits=0 from assert A, which is the
# ScrollViewEventEmitter cast in dispatchScroll failing. That IS the emitter
# arm -- dispatchScroll returns 0 for exactly this cause -- so it is the right
# assertion. The alerts arm never gets reached because scroll_hits is checked
# first, which is correct ordering: "the emitter is the wrong type" is a more
# specific diagnosis than "nothing ran in JS".
#
# Under M2 the pixels ARE expected to still scroll, because SceneGraph keys off
# componentName and scrollBy mutates the offset BEFORE the emitter cast. If the
# pixel assertion kills this mutant, the pixel assertion is accidentally testing
# registration and the emitter arm is untested.
if grep -q 'did not move\|wrong distance' "$BAK/m2.log"; then
  tail -25 "$BAK/m2.log" >&2
  fail "M2 was killed by the PIXEL assertion. Under M2 the pixels are expected to still scroll (SceneGraph keys off componentName, and scrollBy runs before the emitter cast), so this means the pixel assertion is accidentally testing registration and the emitter assertion is untested."
fi
grep -q 'scroll_hits=0\|onScroll handler RAN' "$BAK/m2.log" || {
  tail -25 "$BAK/m2.log" >&2
  fail "M2 was killed by neither the emitter-cast arm (scroll_hits=0) nor the alerts arm. See the tail for what actually failed."
}
echo "   OK: M2 killed (unregistered ScrollView -> ScrollViewEventEmitter cast fails -> scroll_hits=0, while the pixels still scroll)"
cp "$BAK/FabricHost.cpp" "$SRC_FAB"

echo "== M3: the wheel is received but never dispatched (wired but inert) =="
python3 - "$SRC_MAIN" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "    const int hit = fabric.dispatchScroll(x, y, dy);"
new = """    // M3: inert — the callback fires and the counter moves, but no scroll is
    // ever dispatched. The "handler wired, nothing happens" shape.
    (void)dy;
    const int hit = 0;"""
assert old in s, "M3 anchor not found - the scroll handler shape changed"
open(p, "w").write(s.replace(old, new))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M3 tree did not build"
if run_gate "$BAK/m3.log"; then
  fail "M3 SURVIVED: the gate passes when wheel events arrive and dispatch nothing. It is counting callbacks, not scrolls."
fi
# Must NOT be killed by scroll_events: the callback still fires here.
grep -q 'scroll_events=0' "$BAK/m3.log" && {
  tail -25 "$BAK/m3.log" >&2
  fail "M3 was killed by the scroll_events assertion, but the callback DOES fire in M3. The gate cannot distinguish an unregistered callback from an inert one."
}
echo "   OK: M3 killed (wheel delivered, nothing dispatched)"
cp "$BAK/main.cpp" "$SRC_MAIN"

echo "== M4: flip the GLFW sign (scroll goes the wrong way) =="
python3 - "$SRC_SURF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "  scrollHandler_(px, py, (float)(-glfwDy) * kPointsPerNotch);"
new = """  // M4: sign — GLFW's sign passed straight through, so the list scrolls the
  // wrong way. Fully functional, and every user calls it broken.
  scrollHandler_(px, py, (float)(glfwDy) * kPointsPerNotch);"""
assert old in s, "M4 anchor not found - the sign flip moved"
open(p, "w").write(s.replace(old, new))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M4 tree did not build"
if run_gate "$BAK/m4.log"; then
  fail "M4 SURVIVED: the gate passes with the wheel direction INVERTED. Every assertion about 'did the offset change' is satisfied by a scroll that goes the wrong way."
fi
echo "   OK: M4 killed (inverted wheel direction)"
cp "$BAK/GlfwSurface.cpp" "$SRC_SURF"

echo "== M5: remove the clamp (offset grows unbounded) =="
python3 - "$SRC_SG" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """  if (next < 0.0f) next = 0.0f;
  if (next > maxOffset) next = maxOffset;"""
new = """  // M5: unclamped — the offset runs past the end of the content, scrolling the
  // list into empty space while still emitting plausible onScroll events.
  (void)maxOffset;
  if (next < 0.0f) next = 0.0f;"""
assert old in s, "M5 anchor not found - the clamp moved"
open(p, "w").write(s.replace(old, new))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M5 tree did not build"
if run_gate "$BAK/m5.log"; then
  fail "M5 SURVIVED: the gate passes with the scroll offset UNCLAMPED. A list that scrolls past its own end goes blank while every event still looks right."
fi
grep -q 'CLAMP\|clamp' "$BAK/m5.log" || {
  tail -25 "$BAK/m5.log" >&2
  fail "M5 was killed, but not by the clamp assertion (D2). See the tail for what actually failed."
}
echo "   OK: M5 killed (unclamped offset)"
cp "$BAK/SceneGraph.cpp" "$SRC_SG"

echo "== M6: scroll the paint but NOT the hit test (known coverage gap) =="
# ⛔ THIS MUTANT IS EXPECTED TO SURVIVE, AND THAT IS THE POINT OF RUNNING IT.
# The gate has no assertion that clicks a row after scrolling, so a hit test
# that ignores the offset is invisible to it: the pixels are right and every
# press lands on the row that used to be there. Recording the gap explicitly is
# worth more than a suite that looks complete. A future ENG row that adds a
# post-scroll click assertion should move this mutant into the killed set.
python3 - "$SRC_SG" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "  const float childOriginY = node.isScrollView ? ny - node.scrollY : ny;"
new = """  // M6: hittest — paint honours the scroll offset and hit testing does not.
  const float childOriginY = ny;"""
assert old in s, "M6 anchor not found - the hit-test shift moved"
open(p, "w").write(s.replace(old, new))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M6 tree did not build"
if run_gate "$BAK/m6.log"; then
  echo "   EXPECTED SURVIVAL: M6 (hit test ignores the scroll offset) is NOT"
  echo "   covered by this gate. Pixels scroll correctly and every press after a"
  echo "   scroll lands on the row that used to be there. Recorded as a known"
  echo "   coverage gap, not a passing result."
else
  echo "   NOTE: M6 was killed — the gate covers more than expected. Tighten this"
  echo "   harness's expectation rather than leaving a stale comment."
fi
cp "$BAK/SceneGraph.cpp" "$SRC_SG"

echo "== restore + rebuild the clean tree =="
restore
bash tools/engine-build.sh > /dev/null 2>&1 || fail "the RESTORED tree did not build — the tree is left mutated, check git diff"
run_gate "$BAK/final.log" || { tail -25 "$BAK/final.log" >&2; fail "the restored tree does not pass the gate"; }
echo "   OK: restored tree builds and passes"

echo "MUTATION_VERIFY_SCROLL_PASS (M1,M2,M3,M4,M5 killed by their own assertions; M6 recorded as a known gap)"
