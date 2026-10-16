#!/usr/bin/env bash
# Mutation verification for tools/ci-gtransform.sh.
#
# This gate guards a bug that ALREADY SHIPPED on the sibling engine and is
# invisible at runtime, so "it passes" is not enough -- it has to be seen RED
# for the right reason.
#
# Restore by cp and REBUILD between mutants (P9-A: a mutation
# suite that skips the rebuild scores the next mutant against the previous
# mutant's binary and reports a meaningless pass).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable-timeout.sh"  # portable timeout (mac fallback)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SceneGraph.cpp"
trap 'cp "$BACKUP/SceneGraph.cpp" "$SG"; bash tools/engine-build.sh > /tmp/mgt-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

PASS=0
TOTAL=0

run_mutant() {
  local name="$1"
  TOTAL=$((TOTAL + 1))
  echo "--- mutant: $name ---"
  if ! bash tools/engine-build.sh > /tmp/mgt-build.log 2>&1; then
    echo "  BUILD FAILED -- a mutant that does not compile proves nothing"
    grep -E "error:" /tmp/mgt-build.log | head -3 | sed 's/^/     /'
  elif timeout 500 bash tools/ci-gtransform.sh > /tmp/mgt-gate.log 2>&1; then
    echo "  ⛔ NOT CAUGHT -- gate still passed"
    grep -E "GTRANSFORM_GATE_PASS" /tmp/mgt-gate.log | sed 's/^/     /'
  else
    echo "  caught:"
    grep -E "GTRANSFORM_GATE_FAIL" /tmp/mgt-gate.log | head -2 | sed 's/^/     /'
    PASS=$((PASS + 1))
  fi
  cp "$BACKUP/SceneGraph.cpp" "$SG"
  bash tools/engine-build.sh > /tmp/mgt-rebuild.log 2>&1 || true
}

echo "MUTATION_VERIFY_GTRANSFORM_START"

# M1: the ORIGINAL BUG -- never read the matrix at all. This is precisely the
# state skia-platform is in today: the prop exists, nothing consumes it, every
# group's children collapse onto one origin, and nothing logs.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("      node.hasSvgMatrix = !identity;",
            "      node.hasSvgMatrix = false;  // MUTANT M1: matrix never consumed",1)
open(p,"w").write(s)
PY
run_mutant "M1 <G transform> dropped entirely (the skia-platform bug)"

# M2: apply the matrix to the node's OWN painting but restore BEFORE the child
# walk. A group draws no ink of its own, so its children stop moving while a
# transform on a leaf <Path> still works -- a half-fix that looks correct in
# any single-element test.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("""  // Children are positioned relative to this node's frame origin.
  const bool clip = node.overflowHidden;""",
"""  if (svgTransformed) { ImpellerDisplayListBuilderRestore(builder); }  // MUTANT M2
  // Children are positioned relative to this node's frame origin.
  const bool clip = node.overflowHidden;""",1)
s=s.replace("""  // Paired with the save above; must come AFTER the child walk so a group's
  // transform applies to its subtree.
  if (svgTransformed) {
    ImpellerDisplayListBuilderRestore(builder);
  }""","",1)
open(p,"w").write(s)
PY
run_mutant "M2 matrix restored BEFORE children (group subtree not transformed)"

# M3: transpose b and c. Translate and UNIFORM SCALE are unaffected, so this
# passes any test built only from translate() -- it corrupts rotation and skew
# only. It is here to prove the gate's scale probe is load-bearing and to pin
# the column-major layout.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
s=s.replace("""    ImpellerMatrix sm = {{a, b, 0, 0,
                          c, d, 0, 0,
                          0, 0, 1, 0,
                          tx, ty, 0, 1}};""",
"""    ImpellerMatrix sm = {{a, c, 0, 0,
                          b, d, 0, 0,
                          0, 0, 1, 0,
                          tx, ty, 0, 1}};  // MUTANT M3: b/c transposed""",1)
open(p,"w").write(s)
PY
run_mutant "M3 b/c transposed (rotation+skew corrupted, translate unaffected)"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_GTRANSFORM_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_GTRANSFORM_FAIL ($PASS/$TOTAL)"
  exit 1
fi
