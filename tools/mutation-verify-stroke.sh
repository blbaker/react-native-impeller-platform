#!/usr/bin/env bash
# Mutation verification for tools/ci-stroke.sh.
#
# Restore by cp and REBUILD between mutants (docs/STATE.md P9-A: skipping the
# rebuild scores the next mutant against the previous mutant's binary).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable-timeout.sh"  # portable timeout (mac fallback)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SceneGraph.cpp"
trap 'cp "$BACKUP/SceneGraph.cpp" "$SG"; bash tools/engine-build.sh > /tmp/mst-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

PASS=0
TOTAL=0

run_mutant() {
  local name="$1"
  TOTAL=$((TOTAL + 1))
  echo "--- mutant: $name ---"
  if ! bash tools/engine-build.sh > /tmp/mst-build.log 2>&1; then
    echo "  BUILD FAILED -- a mutant that does not compile proves nothing"
    grep -E "error:" /tmp/mst-build.log | head -3 | sed 's/^/     /'
  elif timeout 500 bash tools/ci-stroke.sh > /tmp/mst-gate.log 2>&1; then
    echo "  ⛔ NOT CAUGHT -- gate still passed"
    grep -E "STROKE_GATE_PASS" /tmp/mst-gate.log | sed 's/^/     /'
  else
    echo "  caught:"
    grep -E "STROKE_GATE_FAIL" /tmp/mst-gate.log | head -2 | sed 's/^/     /'
    PASS=$((PASS + 1))
  fi
  cp "$BACKUP/SceneGraph.cpp" "$SG"
  bash tools/engine-build.sh > /tmp/mst-rebuild.log 2>&1 || true
}

echo "MUTATION_VERIFY_STROKE_START"

# M1: gate painting on having a FILL, as the code did before stroke existed.
# Fill+stroke shapes still render perfectly; only stroke-only ones vanish.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("  if (node.isSvgPath && (node.svgHasFill || node.svgHasStroke) &&\n      !node.svgD.empty()) {",
            "  if (node.isSvgPath && node.svgHasFill && !node.svgD.empty()) {  // MUTANT M1",1)
open(p,"w").write(s)
PY
run_mutant "M1 painting gated on fill (stroke-only shapes vanish)"

# M2: one paint, StrokeAndFill -- the tempting implementation. The outline
# takes the FILL's colour, which is invisible on any shape whose fill and
# stroke match.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("            ImpellerColor sc = impellerColor(node.svgStrokeColor, strokeAlpha);",
            "            ImpellerColor sc = impellerColor(node.svgFillColor, strokeAlpha);  // MUTANT M2",1)
open(p,"w").write(s)
PY
run_mutant "M2 stroke drawn in the FILL's colour (shared-paint bug)"

# M3: ignore strokeWidth, leaving Impeller's default. Every outline still
# appears -- just far too thin -- so any "is there an edge?" check stays green.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("            ImpellerPaintSetStrokeWidth(strokePaint, node.svgStrokeWidth);",
            "            // MUTANT M3: strokeWidth ignored",1)
open(p,"w").write(s)
PY
run_mutant "M3 strokeWidth ignored (outline still drawn, wrong thickness)"

# M4: reuse the FILL's opacity for the stroke. Identical output whenever the
# two happen to match, wrong whenever they differ.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("""          const float strokeAlpha =
              std::clamp(node.svgStrokeOpacity, 0.0f, 1.0f) * nodeAlpha;""",
            "          const float strokeAlpha = fillAlpha;  // MUTANT M4",1)
open(p,"w").write(s)
PY
run_mutant "M4 strokeOpacity replaced by fillOpacity"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_STROKE_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_STROKE_FAIL ($PASS/$TOTAL)"
  exit 1
fi
