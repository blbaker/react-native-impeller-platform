#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-world-raster.sh.
#
# ⛔ WHY THIS FILE EXISTS. ci-world-raster.sh was written after the feature
# already compiled green, so it has never been observed to fail. A gate that
# has only ever been green is an unproven instrument. This harness breaks the
# real engine three specific ways and proves the gate goes red on each.
#
# M1 — unregistered component. Remove the WorldComponentDescriptor add() from
#      FabricHost.cpp. <world> mounts as a plain View (ViewProps only) and
#      paints nothing OF ITS OWN, silently. Must die on ARM B (luma mismatch)
#      -- with no image drawn, the world screenshot is flat white, nowhere
#      near the reference's 238-level ramp.
# M2 — inert setter. WorldRasterModule::setPixelsHost stops calling
#      store_->setPixels, so the buffer never reaches the store and the
#      painter's `get()` returns nullptr for the whole run -- the world
#      surface stays blank (paintWorldNode's own "nothing published yet"
#      no-op). Must die on ARM B (luma mismatch): blank vs the reference's
#      full ramp.
# M3 — skipped Y-flip. Remove the Scale(1,-1) call from paintWorldNode's
#      draw, leaving the Translate. The buffer draws upside down. Must die
#      on ARM B (luma mismatch): a vertically mirrored gradient does not
#      luma-match its un-mirrored reference (the ramp is monotonic
#      row-to-row, so flipping it top-to-bottom changes which luma values
#      land in which frequency band relative to the reference's rows --
#      measured below).
#
# Each mutant must be killed by ARM B specifically (the luma comparison),
# proving that arm -- not ARM A, which is a structural node-count check that
# these particular mutants do not touch (M1/M2/M3 all still mount exactly
# one <world>-shaped node; only its pixels are wrong). If a mutant survived,
# ARM A's node-count check could not have saved it -- this is exactly the
# "nodes-alone is vacuous" argument the gate's own header makes, demonstrated
# rather than merely asserted.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC_FABRIC="engine/fabric/FabricHost.cpp"
SRC_MODULE="engine/modules/WorldRasterModule.h"
SRC_SCENE="engine/scenegraph/SceneGraph.cpp"

BAK="$(mktemp -d)"
cp "$SRC_FABRIC" "$BAK/FabricHost.cpp"
cp "$SRC_MODULE" "$BAK/WorldRasterModule.h"
cp "$SRC_SCENE" "$BAK/SceneGraph.cpp"
restore() {
  cp "$BAK/FabricHost.cpp" "$SRC_FABRIC"
  cp "$BAK/WorldRasterModule.h" "$SRC_MODULE"
  cp "$BAK/SceneGraph.cpp" "$SRC_SCENE"
}
trap 'restore; rm -rf "$BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

# ⚠️ MUTANT RESIDUE PRE-FLIGHT. A crashed harness leaves a mutant in the tree
# and its trap does not run on a hard failure; a later gate then "fails"
# mysteriously, unrelated to whatever it happened to be testing.
for marker in "M1: unregistered" "M2: inert" "M3: Y-flip removed"; do
  if grep -rq "$marker" "$SRC_FABRIC" "$SRC_MODULE" "$SRC_SCENE"; then
    fail "mutant residue '$marker' is already in the tree -- restore it before running (git diff)"
  fi
done
grep -q "react::concreteComponentDescriptorProvider<react::WorldComponentDescriptor>" "$SRC_FABRIC" \
  || fail "the fix is NOT PRESENT in the tree (WorldComponentDescriptor not registered) -- a passing gate here would be blind"
grep -q "me.store_->setPixels(id, std::move(pixels), w, h);" "$SRC_MODULE" \
  || fail "the fix is NOT PRESENT in the tree (setPixelsHost does not call store_->setPixels)"

# ⛔ THE EXIT STATUS MUST COME FROM THE GATE, NOT FROM A PIPE.
run_gate() {
  local log="$1"
  set +e
  bash tools/ci-world-raster.sh > "$log" 2>&1
  local rc=$?
  set -e
  return $rc
}

build_or_fail() {
  local what="$1"
  bash tools/engine-build.sh linux x64 > "$BAK/build-$what.log" 2>&1 \
    || { tail -40 "$BAK/build-$what.log" >&2; fail "$what tree did not build"; }
}

echo "== control: unmutated tree must PASS =="
build_or_fail control
if ! run_gate "$BAK/control.log"; then
  tail -30 "$BAK/control.log" >&2
  fail "the gate does not pass on the UNMUTATED tree -- nothing below means anything"
fi
grep -q WORLD_RASTER_GATE_PASS "$BAK/control.log" \
  || fail "control did not print WORLD_RASTER_GATE_PASS"
echo "   OK: control passes on the real, unmutated ENG-09 build"

echo "== M1: unregistered component (drop the WorldComponentDescriptor add()) =="
python3 - "$SRC_FABRIC" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = (
    "  providerRegistry->add(\n"
    "      react::concreteComponentDescriptorProvider<react::WorldComponentDescriptor>());\n"
)
assert s.count(old) == 1, f"M1 anchor not found exactly once (got {s.count(old)}) -- FabricHost.cpp changed"
new = "  // M1: unregistered -- WorldComponentDescriptor add() removed.\n"
open(p, "w").write(s.replace(old, new, 1))
PY
build_or_fail m1
if run_gate "$BAK/m1.log"; then
  fail "M1 SURVIVED: the gate passes with <world> unregistered. An unregistered Fabric component mounts as a plain View and paints nothing -- this is the exact silent failure the gate's header calls out (see ci-svg.sh's rationale, same shape). ARM A (node count) cannot catch this either: an unmounted-as-View <world> is still ONE node."
fi
grep -q "luma histogram L1 distance" "$BAK/m1.log" || {
  tail -30 "$BAK/m1.log" >&2
  fail "M1 killed, but not by ARM B (luma). See the tail above -- if it died on ARM A that is a different, unintended failure mode."
}
echo "   OK: M1 killed by ARM B (luma mismatch -- unregistered component painted nothing)"
cp "$BAK/FabricHost.cpp" "$SRC_FABRIC"

echo "== M2: inert setter (setPixelsHost stops writing into the store) =="
python3 - "$SRC_MODULE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "    me.store_->setPixels(id, std::move(pixels), w, h);\n    return jsi::Value::undefined();"
assert s.count(old) == 1, f"M2 anchor not found exactly once (got {s.count(old)}) -- WorldRasterModule.h changed"
new = (
    "    // M2: inert -- the call is fully validated (throws on a bad buffer\n"
    "    // exactly as before) but never publishes into the store, so the\n"
    "    // painter's get() sees nothing for this id, ever.\n"
    "    (void)pixels;\n"
    "    return jsi::Value::undefined();"
)
open(p, "w").write(s.replace(old, new, 1))
PY
build_or_fail m2
if run_gate "$BAK/m2.log"; then
  fail "M2 SURVIVED: the gate passes when setPixels never publishes into WorldRasterStore. This is the 'fix wired, does nothing' shape -- the JS call succeeds (no throw), the module method runs, but nothing reaches the painter, so <world> stays permanently blank (paintWorldNode's own 'nothing published yet' branch)."
fi
grep -q "luma histogram L1 distance" "$BAK/m2.log" || {
  tail -30 "$BAK/m2.log" >&2
  fail "M2 killed, but not by ARM B (luma). See the tail above."
}
echo "   OK: M2 killed by ARM B (luma mismatch -- stale/blank world surface)"
cp "$BAK/WorldRasterModule.h" "$SRC_MODULE"

echo "== M3: skipped Y-flip (world buffer renders upside down) =="
python3 - "$SRC_SCENE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
i = s.index("bool SceneGraph::paintWorldNode(")
j = s.index("\n}\n", i)
seg = s[i:j]
old = (
    "ImpellerDisplayListBuilderTranslate(builder, x, y + h);\n"
    "  ImpellerDisplayListBuilderScale(builder, 1.0f, -1.0f);"
)
assert seg.count(old) == 1, f"M3 anchor not found exactly once within paintWorldNode (got {seg.count(old)})"
new = (
    "ImpellerDisplayListBuilderTranslate(builder, x, y);\n"
    "  // M3: Y-flip removed -- the world buffer now draws top-to-bottom into a\n"
    "  // GL texture whose v=0 is the BOTTOM row, i.e. upside down."
)
new_seg = seg.replace(old, new, 1)
assert new_seg != seg
open(p, "w").write(s[:i] + new_seg + s[j:])
PY
build_or_fail m3
if run_gate "$BAK/m3.log"; then
  fail "M3 SURVIVED: the gate passes with paintWorldNode's Y-flip removed. The world buffer renders upside down against a GL texture whose v=0 row is the BOTTOM row -- this is the exact bug the header comment at SceneGraph.cpp's Y-FLIP THE DRAW block warns about."
fi
grep -q "positional luma check failed" "$BAK/m3.log" || {
  tail -30 "$BAK/m3.log" >&2
  fail "M3 killed, but not by the POSITIONAL luma check. A plain histogram distance is orientation-blind (see luma-histogram-diff.py's header) and would NOT catch this mutant -- if M3 is dying some other way, the gate is not actually proving orientation is correct. See the tail above."
}
echo "   OK: M3 killed by ARM B's positional check (histogram alone is orientation-blind)"
cp "$BAK/SceneGraph.cpp" "$SRC_SCENE"

echo "== restore + rebuild =="
restore
trap - EXIT
RESTORE_LOG="$(mktemp)"
if ! bash tools/engine-build.sh linux x64 > "$RESTORE_LOG" 2>&1; then
  tail -40 "$RESTORE_LOG" >&2
  fail "restored tree did not build (log: $RESTORE_LOG)"
fi
rm -f "$RESTORE_LOG"
rm -rf "$BAK"
echo "MUTATION_VERIFY_PASS (3/3 killed: M1 unregistered-component, M2 inert-setter, M3 skipped-Y-flip -- all via ARM B/luma)"
