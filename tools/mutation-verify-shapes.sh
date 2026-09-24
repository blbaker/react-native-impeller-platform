#!/usr/bin/env bash
# Mutation verification for tools/ci-shapes.sh.
#
# Restore by cp and REBUILD between mutants (docs/STATE.md P9-A).
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
trap 'restore_src; bash tools/engine-build.sh > /tmp/msh-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

PASS=0
TOTAL=0

run_mutant() {
  local name="$1"
  TOTAL=$((TOTAL + 1))
  echo "--- mutant: $name ---"
  if ! bash tools/engine-build.sh > /tmp/msh-build.log 2>&1; then
    echo "  BUILD FAILED -- a mutant that does not compile proves nothing"
    grep -E "error:" /tmp/msh-build.log | head -3 | sed 's/^/     /'
  elif timeout 500 bash tools/ci-shapes.sh > /tmp/msh-gate.log 2>&1; then
    echo "  ⛔ NOT CAUGHT -- gate still passed"
  else
    echo "  caught:"
    grep -E "SHAPES_GATE_FAIL" /tmp/msh-gate.log | head -2 | sed 's/^/     /'
    PASS=$((PASS + 1))
  fi
  restore_src
  bash tools/engine-build.sh > /tmp/msh-rebuild.log 2>&1 || true
}

echo "MUTATION_VERIFY_SHAPES_START"

# M1: THE SILENT ONE. Unregister RNSVGCircle from the provider registry while
# knownComponentNames() still advertises it. RN falls back, the component
# mounts, paints nothing, and logs cleanly.
python3 - <<'PY'
p="engine/fabric/FabricHost.cpp"; s=open(p).read()
s=s.replace("""  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGCircleComponentDescriptor>());""",
"""  // MUTANT M1: RNSVGCircle unregistered but still advertised""",1)
open(p,"w").write(s)
PY
run_mutant "M1 RNSVGCircle unregistered but still advertised (silent failure)"

# M2: ignore the rect's corner radii and always emit a square rect. Every
# "did the rect paint?" check stays green; only the empty-corner probe sees it.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("        if (rx > 0.0f && ry > 0.0f) {",
            "        if (false) {  // MUTANT M2: corner radii ignored",1)
open(p,"w").write(s)
PY
run_mutant "M2 rect corner radii ignored (square corners)"

# M3: draw the ellipse as a CIRCLE of radius rx. It still paints a green blob
# in the right place -- only the point outside the y-radius exposes it.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("""      node.svgD = ellipseToPathData(svgLength(pp->cx), svgLength(pp->cy),
                                    svgLength(pp->rx), svgLength(pp->ry));""",
"""      node.svgD = ellipseToPathData(svgLength(pp->cx), svgLength(pp->cy),
                                    svgLength(pp->rx), svgLength(pp->rx));  // MUTANT M3""",1)
open(p,"w").write(s)
PY
run_mutant "M3 ellipse drawn as a circle of radius rx"

# ⛔ M4 IS NOT "Line keeps its default black fill" -- THAT ONE IS UNOBSERVABLE.
#
# It was written, run, and NOT caught, and the gate is right: a straight
# <Line> encloses ZERO area, so filling it produces no pixels no matter what
# colour the fill is (verified -- the frame contains no black pixels at all
# with the fill left in). Dropping node.svgHasFill for Line is correctness
# hygiene, not something a raster probe can ever assert.
#
# So M4 mutates something a probe CAN see: the Line's endpoints, swapping y2
# for y1's value would leave a horizontal line unchanged, so instead shorten
# the line to a point. It still "draws" (a round/butt cap dot) but no longer
# reaches the probe.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("""      std::snprintf(buf, sizeof(buf), "M%g %g L%g %g",
                    svgLength(pp->x1), svgLength(pp->y1),
                    svgLength(pp->x2), svgLength(pp->y2));""",
"""      std::snprintf(buf, sizeof(buf), "M%g %g L%g %g",
                    svgLength(pp->x1), svgLength(pp->y1),
                    svgLength(pp->x1), svgLength(pp->y1));  // MUTANT M4""",1)
open(p,"w").write(s)
PY
run_mutant "M4 Line ignores x2/y2 (degenerate, never reaches the probe)"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_SHAPES_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_SHAPES_FAIL ($PASS/$TOTAL)"
  exit 1
fi
