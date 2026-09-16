#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-eng08.sh.
#
# ⛔ WHY THIS FILE EXISTS. ci-eng08.sh was written AFTER the fix, so it has never
# been observed to fail. A gate that has only ever been green is an unproven
# instrument. Worse, the OBVIOUS version of this gate — screenshot the window and
# assert something painted — passes with the contentsScale setter deleted,
# because the app's pixels ARE painted, correctly coloured, into the top-left
# quarter. It would be green on the exact bug the gate exists for. This harness
# proves ci-eng08.sh goes red on each real regression shape.
#
# Each mutant removes/breaks one specific property and must be killed by the
# assertion aimed at it. A mutant killed by the wrong assertion is not evidence.
#
# M1 — delete GlfwCocoaSetLayerScale(window_) from init() (the frame-one site).
#      The pre-fix state exactly. The layer keeps its 1.0 default while the
#      display is 2x. Must die on the equality assertion (contents != backing).
# M2 — the setter is called but its body is inert (returns before setting).
#      "Wired but inert" — the fix present in shape but doing nothing. Must ALSO
#      die on the equality assertion; this proves the gate reads the layer's
#      REAL contentsScale, not the mere presence of the call.
# M3 — the setter writes the literal 1.0 instead of backingScaleFactor. The
#      wrong-constant regression (someone hardcodes a scale). Must die on the
#      equality assertion.
# M4 — delete the ENG-08 observable fprintf. No layer line prints, so the
#      extractor scrapes empty. Must die on the NUMERIC PRECONDITION (step 0),
#      NOT on the equality assertion — an empty value must fail closed, not make
#      `[ "" = "" ]` pass open.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC_MM="engine/host/GlfwCocoaView.mm"
SRC_SURF="engine/host/GlfwSurface.cpp"

BAK="$(mktemp -d)"
cp "$SRC_MM" "$BAK/GlfwCocoaView.mm"
cp "$SRC_SURF" "$BAK/GlfwSurface.cpp"
restore() {
  cp "$BAK/GlfwCocoaView.mm" "$SRC_MM"
  cp "$BAK/GlfwSurface.cpp" "$SRC_SURF"
}
trap 'restore; rm -rf "$BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

# ⚠️ MUTANT RESIDUE PRE-FLIGHT. A crashed harness leaves a mutant in the tree and
# its trap does not run on a hard failure; a later gate then "fails" mysteriously.
for marker in "M2: inert" "M3: wrong constant"; do
  if grep -rq "$marker" "$SRC_MM" "$SRC_SURF"; then
    fail "mutant residue '$marker' is already in the tree — restore it before running (git diff)"
  fi
done
grep -q "GlfwCocoaSetLayerScale(window_);" "$SRC_SURF" \
  || fail "the fix is NOT PRESENT in the tree (no GlfwCocoaSetLayerScale call) — a passing gate here would be blind"

# ⚠️ THE EXIT STATUS MUST COME FROM THE GATE, NOT FROM A PIPE.
run_gate() {
  local log="$1"
  set +e
  DISPLAY="${DISPLAY:-:0}" bash tools/ci-eng08.sh > "$log" 2>&1
  local rc=$?
  set -e
  return $rc
}

echo "== control: unmutated tree must PASS =="
if ! run_gate "$BAK/control.log"; then
  tail -25 "$BAK/control.log" >&2
  fail "the gate does not pass on the UNMUTATED tree — nothing below means anything"
fi
# A SKIP is not a PASS. On a 1x display the gate cannot discriminate, so this
# harness cannot verify anything here — say so and stop rather than reporting a
# hollow success.
if grep -q ENG08_GATE_SKIP "$BAK/control.log"; then
  cat "$BAK/control.log" >&2
  fail "control SKIPPED (1x display). Mutation verification is meaningless on a 1x display — run this on a Retina Mac."
fi
grep -q ENG08_GATE_PASS "$BAK/control.log" \
  || fail "control did not print ENG08_GATE_PASS"
echo "   OK: control passes with the equality assertion live on a Retina display"

echo "== M1: delete GlfwCocoaSetLayerScale(window_) from init() =="
python3 - "$SRC_SURF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# Anchor on the comment+call at the INIT site so we do not touch the identical
# call in consumeDirty(). The consumeDirty site is the change-time path, which a
# no-resize gate never exercises anyway; the init site is the one under test.
anchor = "// before the first present, or frame one paints a quarter window on hi-dpi.\n  GlfwCocoaSetLayerScale(window_);\n"
assert anchor in s, "M1 anchor not found - the init-site call/comment changed"
open(p, "w").write(s.replace(anchor, "// M1: frame-one setter removed (pre-fix state)\n"))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M1 tree did not build"
if run_gate "$BAK/m1.log"; then
  fail "M1 SURVIVED: the gate passes with the frame-one contentsScale setter deleted. That IS the pre-fix bug -- the window under-renders to a quarter on frame one. The number arm alone cannot see this (AppKit/consumeDirty auto-correct the read-back); the EXTENT arm must."
fi
# ⛔ M1 MUST DIE ON THE EXTENT ARM, NOT THE NUMBER ARM. Measured on the Mac's 5K
# panel: with init()'s setter deleted the read-back number STILL read equal, so
# the equality assertion could not kill M1 -- only the frame-one painted extent
# (a quarter of the window) can. If M1 dies on 'does not match backing_scale'
# instead, the extent arm is not doing the work and a future edit that removes
# it would silently let M1 survive again.
if grep -q 'does not match backing_scale' "$BAK/m1.log"; then
  tail -25 "$BAK/m1.log" >&2
  fail "M1 was killed by the NUMBER arm, not the extent arm. On a real 2x-Main display the number is auto-corrected, so this kill is display-dependent and the extent arm is unproven. See the tail above."
fi
grep -q 'fills hspan=.* below' "$BAK/m1.log" || grep -q 'frame-one paint fills' "$BAK/m1.log" || {
  tail -25 "$BAK/m1.log" >&2
  fail "M1 killed, but NOT by the frame-one extent assertion. See the tail above."
}
echo "   OK: M1 killed (frame-one painted extent is a quarter of the window)"
cp "$BAK/GlfwSurface.cpp" "$SRC_SURF"

echo "== M2: the setter is called but its body is inert =="
python3 - "$SRC_MM" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "  CALayer* layer = [view layer];\n  if (!layer) return;\n  layer.contentsScale = [nsWindow backingScaleFactor];\n}"
new = "  CALayer* layer = [view layer];\n  if (!layer) return;\n  // M2: inert — the setter is still called from init(), but sets nothing. The\n  // \"fix wired, does nothing\" shape. A gate that checks call PRESENCE passes.\n  (void)layer;\n}"
assert old in s, "M2 anchor not found - the setter body changed"
open(p, "w").write(s.replace(old, new))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M2 tree did not build"
if run_gate "$BAK/m2.log"; then
  fail "M2 SURVIVED: the gate passes when the setter is called but sets nothing. It is checking that the call EXISTS, not that the layer's real contentsScale changed."
fi
grep -q 'does not match backing_scale' "$BAK/m2.log" || {
  tail -25 "$BAK/m2.log" >&2
  fail "M2 killed, but not by the equality assertion — the gate must read the layer's REAL contentsScale. See the tail above."
}
echo "   OK: M2 killed (gate reads real layer state, not call presence)"
cp "$BAK/GlfwCocoaView.mm" "$SRC_MM"

echo "== M3: the setter writes the literal 1.0 instead of backingScaleFactor =="
python3 - "$SRC_MM" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "  layer.contentsScale = [nsWindow backingScaleFactor];"
new = "  // M3: wrong constant — hardcodes 1.0 instead of the display's backing scale.\n  layer.contentsScale = 1.0;"
assert old in s, "M3 anchor not found - the setter assignment changed"
# Only the setter assigns; the readback RETURNS layer.contentsScale, so this is
# unambiguous.
open(p, "w").write(s.replace(old, new))
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M3 tree did not build"
if run_gate "$BAK/m3.log"; then
  fail "M3 SURVIVED: the gate passes with contentsScale hardcoded to 1.0."
fi
grep -q 'does not match backing_scale' "$BAK/m3.log" || {
  tail -25 "$BAK/m3.log" >&2
  fail "M3 killed, but not by the equality assertion. See the tail above."
}
echo "   OK: M3 killed (equality: 1.00 != backing)"
cp "$BAK/GlfwCocoaView.mm" "$SRC_MM"

echo "== M4: delete the ENG-08 observable fprintf =="
python3 - "$SRC_SURF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
start = s.index("  // ENG-08 OBSERVABLE.")
end = s.index("GlfwCocoaBackingScale(window_));\n", start) + len("GlfwCocoaBackingScale(window_));\n")
block = s[start:end]
assert "fprintf" in block, "M4 anchor not found - the observable block changed"
open(p, "w").write(s[:start] + "  // M4: observable removed\n" + s[end:])
PY
bash tools/engine-build.sh > /dev/null 2>&1 || fail "M4 tree did not build"
if run_gate "$BAK/m4.log"; then
  fail "M4 SURVIVED: the gate passes with no layer line printed. An empty extractor made an equality of empties pass OPEN — step 0 is not fail-closed."
fi
grep -q 'no numeric contents_scale' "$BAK/m4.log" || {
  tail -25 "$BAK/m4.log" >&2
  fail "M4 killed, but NOT by the numeric precondition (step 0). A missing line must fail closed there, not fall through to the equality check. See the tail above."
}
echo "   OK: M4 killed (numeric precondition fails closed on a missing line)"
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
echo "MUTATION_VERIFY_PASS (4/4 killed: M1 no-frame-one-setter, M2 inert-setter, M3 wrong-constant, M4 missing-observable)"
