#!/usr/bin/env bash
# Mutation verification for tools/ci-gradient.sh.
#
# Restore by cp and REBUILD between mutants (P9-A).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable-timeout.sh"  # portable timeout (mac fallback)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
FH="engine/fabric/FabricHost.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SceneGraph.cpp"
cp "$FH" "$BACKUP/FabricHost.cpp"
restore_src() { cp "$BACKUP/SceneGraph.cpp" "$SG"; cp "$BACKUP/FabricHost.cpp" "$FH"; }
trap 'restore_src; bash tools/engine-build.sh > /tmp/mgr-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

PASS=0
TOTAL=0

run_mutant() {
  local name="$1"
  TOTAL=$((TOTAL + 1))
  echo "--- mutant: $name ---"
  if ! bash tools/engine-build.sh > /tmp/mgr-build.log 2>&1; then
    echo "  BUILD FAILED -- a mutant that does not compile proves nothing"
    grep -E "error:" /tmp/mgr-build.log | head -3 | sed 's/^/     /'
  elif timeout 500 bash tools/ci-gradient.sh > /tmp/mgr-gate.log 2>&1; then
    echo "  ⛔ NOT CAUGHT -- gate still passed"
  else
    echo "  caught:"
    grep -E "GRADIENT_GATE_FAIL" /tmp/mgr-gate.log | head -1 | sed 's/^/     /'
    PASS=$((PASS + 1))
  fi
  restore_src
  bash tools/engine-build.sh > /tmp/mgr-rebuild.log 2>&1 || true
}

echo "MUTATION_VERIFY_GRADIENT_START"

# M1: THE BUG THIS FEATURE SHIPPED WITH. Test the paint guard on the colour
# flags only. A url(#id) brush resolves to neither, so every gradient-filled
# shape is skipped: brush parsed fine, registry built fine, zero pixels.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("""      (node.svgHasFill || node.svgHasStroke || node.svgFillIsRef ||
       node.svgStrokeIsRef) &&""",
"""      (node.svgHasFill || node.svgHasStroke) &&  // MUTANT M1""",1)
open(p,"w").write(s)
PY
run_mutant "M1 paint guard ignores reference brushes (the bug that shipped)"

# M2: resolve objectBoundingBox units against the node's LAYOUT FRAME instead
# of the path's bounds. Every RNSVG frame is the whole surface, so the ramp
# stretches across the canvas -- it still paints, just wrong.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("""              ImpellerRect b = {0, 0, 0, 0};
              ImpellerPathGetBounds(path, &b);
              ImpellerColorSource src = makeGradientSource(
                  git->second, b.x, b.y, b.width, b.height, fillAlpha);""",
"""              ImpellerColorSource src = makeGradientSource(
                  git->second, x, y, w, h, fillAlpha);  // MUTANT M2""",1)
open(p,"w").write(s)
PY
run_mutant "M2 gradient box = layout frame, not path bounds"

# M3: paint an unresolved url(#id) with the fill colour anyway. A dangling
# reference then silently paints BLACK (rnsvg's spec default), which looks
# like a deliberate design choice rather than a missing def.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("""            auto git = gradients_.find(node.svgFillRef);
            if (git != gradients_.end()) {""",
"""            auto git = gradients_.find(node.svgFillRef);
            if (git == gradients_.end()) {  // MUTANT M3
              ImpellerColor fc = impellerColor(node.svgFillColor, fillAlpha);
              ImpellerPaint mp = ImpellerPaintNew();
              ImpellerPaintSetColor(mp, &fc);
              ImpellerDisplayListBuilderDrawPath(builder, path, mp);
              ImpellerPaintRelease(mp);
            }
            if (git != gradients_.end()) {""",1)
open(p,"w").write(s)
PY
run_mutant "M3 dangling url(#id) falls back to a colour instead of nothing"

# ⛔ TWO M4 CANDIDATES WERE EQUIVALENT MUTANTS. THIS IS THE THIRD.
#
# (a) "unregister RNSVGDefs" -- not caught, and the gate is RIGHT. Measured
#     with --log-mutations: the node still mounts as `CREATE type=RNSVGDefs`
#     via RN's fallback, and both gradient children still mount and register.
#     The registry is keyed off the gradient nodes themselves, never their
#     parent. Registering Defs is correct, but not load-bearing here.
#
# (b) "cast the stop colour through int32 instead of int64" -- also not
#     caught, also correct. The stops arrive NEGATIVE (measured: red=-65536.0,
#     blue=-16776961.0, white=-1.0 -- signed int32 packing), and for a negative
#     value the two casts are identical. Only the fill brush's JSON `payload`
#     arrives positive and actually needs int64.
#
# Both were written, run, and honestly scored as misses rather than quietly
# dropped. A suite that counts an equivalent mutant as a catch is a false
# certificate.
#
# M4 now reverses the linear gradient's endpoints: it still paints a perfect
# red->blue ramp, just backwards, so only the end-colour assertions see it.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("""    return ImpellerColorSourceCreateLinearGradientNew(
        &p0, &p1, (uint32_t)n, colors.data(), stops.data(),
        kImpellerTileModeClamp, nullptr);""",
"""    return ImpellerColorSourceCreateLinearGradientNew(
        &p1, &p0, (uint32_t)n, colors.data(), stops.data(),  // MUTANT M4
        kImpellerTileModeClamp, nullptr);""",1)
open(p,"w").write(s)
PY
run_mutant "M4 linear gradient endpoints reversed (ramp runs backwards)"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_GRADIENT_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_GRADIENT_FAIL ($PASS/$TOTAL)"
  exit 1
fi
