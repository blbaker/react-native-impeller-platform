#!/usr/bin/env bash
# Mutation verification for tools/ci-svg.sh.
#
# This gate's whole purpose is to catch failures that are SILENT -- an SVG path
# that mounts, counts as painted, and lays down no ink. A gate for a silent bug
# is worthless until it has been seen RED, because "green" and "blind" look the
# same from the outside.
#
# Each mutant breaks the ENGINE, never the checker.
#
# ⚠️ Restore by COPY and REBUILD between mutants. Restoring source without
# rebuilding leaves the PREVIOUS mutant's binary installed, and the next mutant
# is then scored against the wrong engine -- that exact bug made the animation
# suite report a pass for the wrong reason (see docs/STATE.md P9-A).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable-timeout.sh"  # portable timeout (mac fallback)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
FH="engine/fabric/FabricHost.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SceneGraph.cpp"
cp "$FH" "$BACKUP/FabricHost.cpp"

restore_src() {
  cp "$BACKUP/SceneGraph.cpp" "$SG"
  cp "$BACKUP/FabricHost.cpp" "$FH"
}
trap 'restore_src; bash tools/engine-build.sh > /tmp/msvg-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

PASS=0
TOTAL=0

run_mutant() {
  local name="$1"
  TOTAL=$((TOTAL + 1))
  echo "--- mutant: $name ---"
  if ! bash tools/engine-build.sh > /tmp/msvg-build.log 2>&1; then
    echo "  BUILD FAILED -- a mutant that does not compile proves nothing"
    grep -E "error:" /tmp/msvg-build.log | head -3 | sed 's/^/     /'
  elif timeout 500 bash tools/ci-svg.sh > /tmp/msvg-gate.log 2>&1; then
    echo "  ⛔ NOT CAUGHT -- gate still passed:"
    grep -E "SVG_GATE_PASS|solid=" /tmp/msvg-gate.log | sed 's/^/     /'
  else
    echo "  caught:"
    grep -E "SVG_GATE_FAIL" /tmp/msvg-gate.log | head -2 | sed 's/^/     /'
    PASS=$((PASS + 1))
  fi
  restore_src
  bash tools/engine-build.sh > /tmp/msvg-rebuild.log 2>&1 || true
}

echo "MUTATION_VERIFY_SVG_START"

# M1: unregister RNSVGPath from the PROVIDER REGISTRY ONLY, leaving
# knownComponentNames() advertising it. This is THE failure mode P9 exists to
# defend against: RN takes a fallback path, the component mounts, nothing
# paints, and the log stays clean. If the gate cannot see this, it is not a
# gate.
python3 - <<'PY'
p="engine/fabric/FabricHost.cpp"; s=open(p).read()
s=s.replace("""      react::concreteComponentDescriptorProvider<react::RNSVGPathComponentDescriptor>());""",
            """      react::concreteComponentDescriptorProvider<react::RNSVGGroupComponentDescriptor>());  // MUTANT M1""",1)
open(p,"w").write(s)
PY
run_mutant "M1 RNSVGPath unregistered but still advertised (the silent failure)"

# M2: ignore fillOpacity in the effective alpha. Solid paths still paint, so a
# gate that only checked "did something appear" stays green -- only the
# per-path ramp comparison can see it. This is the HostApp mark's requirement.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("""          const float alpha = std::clamp(node.svgFillOpacity, 0.0f, 1.0f) *
                              std::clamp(node.opacity, 0.0f, 1.0f);""",
            """          const float alpha = std::clamp(node.opacity, 0.0f, 1.0f);  // MUTANT M2""",1)
open(p,"w").write(s)
PY
run_mutant "M2 fill-opacity ignored (per-path ramp collapses)"

# M3: the ORIGINAL BUG, re-introduced. Read the brush payload with isInt()
# only. Every opaque colour packs alpha into the top byte, lands above
# INT32_MAX, arrives from JSON as a double, and is silently rejected -- so
# every fill vanishes. This mutant is here because the bug SHIPPED and was
# invisible until a pixel gate existed.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("""  if (!payload->isNumber()) return false;  // unresolved brush""",
            """  if (!payload->isInt()) return false;  // MUTANT M3: the original bug""",1)
open(p,"w").write(s)
PY
run_mutant "M3 brush payload read as isInt() only (the bug that shipped)"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_SVG_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_SVG_FAIL ($PASS/$TOTAL)"
  exit 1
fi
