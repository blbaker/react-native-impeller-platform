#!/usr/bin/env bash
# MUTATION TEST for tools/ci-eng06.sh.
#
# WHY: this gate was written AFTER the defect it grades was already fixed, so
# nobody has ever watched it go red for the real reason. It has also failed
# twice for WRONG reasons during authoring (a threshold that hid a dim ramp, a
# midpoint split that put the subject inside the control), which is exactly the
# profile of a gate that passes for the wrong reason too.
#
# Three mutants, each aimed at one arm, each applied to the ENGINE SOURCE and
# rebuilt -- not to the fixture, because a fixture edit proves the fixture works:
#
#   M1  re-stub schedulerShouldSynchronouslyUpdateViewOnUIThread
#       -> the ORIGINAL defect. Pump ticks, props computed, dropped on the
#          floor. Expect the props arm (or the pixel arm) to name it.
#
#   M2  do not advance the animation clock (drop advanceAnimationClock())
#       -> RN's drivers interpolate on elapsed ms, so every frame samples t=0.
#          Ticks stay perfect. Expect the pixel arm to go red.
#
#   M3  advance the clock by WALL TIME instead of the frame counter
#       -> the subtlest one, and the whole point of acceptance item (c): a
#          ~1000fps headless loop makes 30 and 45 frames nearly the same
#          instant, so the --frames-must-change-the-value arm must catch it.
#
# Each mutant is reverted and the engine rebuilt before the next, so a failure
# midway cannot leave a mutated engine staged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FABRIC="engine/fabric/FabricHost.cpp"
HOSTCPP="engine/runtime/ReactHost.cpp"
BACKUP="$(mktemp -d)"
cp "$FABRIC"  "$BACKUP/FabricHost.cpp"
cp "$HOSTCPP" "$BACKUP/ReactHost.cpp"

restore() {
  cp "$BACKUP/FabricHost.cpp"  "$FABRIC"
  cp "$BACKUP/ReactHost.cpp"   "$HOSTCPP"
}
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2; rm -rf "$BACKUP"' EXIT

build() { bash tools/engine-build.sh > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-eng06.sh > "$1" 2>&1; }

assert_changed() {
  cmp -s "$1" "$2" && { echo "MUTATE_FAIL: mutant did not change $1 -- the pattern did not match, so nothing was tested" >&2; exit 1; }
  return 0
}

echo "== BASELINE: the gate must be GREEN before any mutation means anything =="
build "$BACKUP/base-build.log"
gate "$BACKUP/base.log" || { tail -15 "$BACKUP/base.log" >&2; echo "MUTATE_FAIL: ci-eng06.sh is already red" >&2; exit 1; }
grep -q ENG06_PASS "$BACKUP/base.log" || { echo "MUTATE_FAIL: baseline printed no ENG06_PASS" >&2; exit 1; }
echo "   $(grep ENG06_PASS "$BACKUP/base.log")"

# ---------------------------------------------------------------------------
echo
echo "== M1: re-stub the synchronous prop path (THE original ENG-06 defect) =="
python3 - "$FABRIC" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
start = s.index("  void schedulerShouldSynchronouslyUpdateViewOnUIThread(\n      react::Tag tag, const folly::dynamic& props) override {")
end = s.index("  void schedulerDidUpdateShadowTree(", start)
s = s[:start] + "  void schedulerShouldSynchronouslyUpdateViewOnUIThread(\n      react::Tag, const folly::dynamic&) override {}\n" + s[end:]
open(p, "w").write(s)
PY
assert_changed "$FABRIC" "$BACKUP/FabricHost.cpp"
build "$BACKUP/m1-build.log"
if gate "$BACKUP/m1.log"; then
  echo "MUTATE_FAIL: M1 SURVIVED -- the animation prop path is a no-op and ci-eng06 stayed GREEN." >&2
  echo "             This gate cannot detect the defect it was written for." >&2
  exit 1
fi
grep -qE 'directprop_updates=0|Animated value never moved|never printed directprop' "$BACKUP/m1.log" \
  || { echo "MUTATE_FAIL: M1 killed the gate for the WRONG reason:" >&2; grep ENG06_FAIL "$BACKUP/m1.log" >&2; exit 1; }
echo "   M1 killed: $(grep ENG06_FAIL "$BACKUP/m1.log" | head -1 | cut -c1-140)"
cp "$BACKUP/FabricHost.cpp" "$FABRIC"

# ---------------------------------------------------------------------------
echo
echo "== M2: never advance the animation clock =="
python3 - "$HOSTCPP" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("  advanceAnimationClock();\n", "  // MUTANT M2: clock not advanced\n", 1)
open(p, "w").write(s)
PY
assert_changed "$HOSTCPP" "$BACKUP/ReactHost.cpp"
build "$BACKUP/m2-build.log"
if gate "$BACKUP/m2.log"; then
  echo "MUTATE_FAIL: M2 SURVIVED -- the animation clock never advances and the gate stayed GREEN." >&2
  echo "             Ticks alone are being graded; the pixel arm is blind." >&2
  exit 1
fi
grep -qE 'Animated value never moved|got DIMMER|rendered the SAME animated value' "$BACKUP/m2.log" \
  || { echo "MUTATE_FAIL: M2 killed the gate for the WRONG reason:" >&2; grep ENG06_FAIL "$BACKUP/m2.log" >&2; exit 1; }
echo "   M2 killed: $(grep ENG06_FAIL "$BACKUP/m2.log" | head -1 | cut -c1-140)"
cp "$BACKUP/ReactHost.cpp" "$HOSTCPP"

# ---------------------------------------------------------------------------
echo
echo "== M3: use WALL TIME instead of the frame counter (acceptance item c) =="
python3 - "$HOSTCPP" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """void ReactHost::installFrameCountedAnimationClock() {
  g_animationFrames.store(0, std::memory_order_relaxed);
  facebook::react::g_setNativeAnimatedNowTimestampFunction(&frameCountedNow);
}"""
new = """void ReactHost::installFrameCountedAnimationClock() {
  // MUTANT M3: leave RN's default steady_clock in place.
  g_animationFrames.store(0, std::memory_order_relaxed);
}"""
assert old in s, "M3 pattern not found"
open(p, "w").write(s.replace(old, new, 1))
PY
assert_changed "$HOSTCPP" "$BACKUP/ReactHost.cpp"
build "$BACKUP/m3-build.log"
if gate "$BACKUP/m3.log"; then
  echo "MUTATE_FAIL: M3 SURVIVED -- the animation runs on WALL TIME and the gate stayed GREEN." >&2
  echo "             Acceptance item (c), '--frames is the clock', is not actually being asserted." >&2
  exit 1
fi
grep -qE 'rendered the SAME animated value|distinct animated green sums|Animated value never moved|got DIMMER' "$BACKUP/m3.log" \
  || { echo "MUTATE_FAIL: M3 killed the gate for the WRONG reason:" >&2; grep ENG06_FAIL "$BACKUP/m3.log" >&2; exit 1; }
echo "   M3 killed: $(grep ENG06_FAIL "$BACKUP/m3.log" | head -1 | cut -c1-140)"
cp "$BACKUP/ReactHost.cpp" "$HOSTCPP"

# ---------------------------------------------------------------------------
echo
echo "== RESTORE: rebuild the clean engine and re-confirm GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate is RED after restore -- a mutant leaked" >&2; exit 1; }
echo "   $(grep ENG06_PASS "$BACKUP/final.log")"

echo
echo "MUTATE_ENG06_OK -- 3 mutants, 3 killed, engine restored and green"
