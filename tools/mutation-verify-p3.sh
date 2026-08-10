#!/usr/bin/env bash
# MUTATION VERIFICATION for the P3 conformance gate.
#
# A gate that has never been seen RED is a hypothesis. This breaks the engine in
# six specific ways and requires tools/ci-p3.sh to fail on each, then restores
# the tree and requires it to pass again.
#
# EVERY mutant here leaves every other signal healthy: exit code 0, no JS
# exception, a complete mutation log, all 8 nodes painted, and a frame that
# looks entirely plausible in a thumbnail. That is deliberate — these are the
# regressions a screenshot review waves through, so the gate has to be the thing
# that catches them.
#
# THE MUTANT MUST ACTUALLY APPLY. Every patch below asserts its pattern was
# found. A mutation script whose replacement silently no-ops reports a green
# gate as "caught nothing" or, worse, as passing — and that is exactly what
# happened to the P2 M2 mutant when this file's paint code was refactored: the
# pattern it searched for no longer existed and the mutant became a no-op.
set -euo pipefail
cd "$(dirname "$0")/.."

SG="engine/scenegraph/SceneGraph.cpp"
TLM="engine/text/ImpellerTextLayoutManager.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SceneGraph.cpp"
cp "$TLM" "$BACKUP/ImpellerTextLayoutManager.cpp"
restore_files_only() {
  cp "$BACKUP/SceneGraph.cpp" "$SG"
  cp "$BACKUP/ImpellerTextLayoutManager.cpp" "$TLM"
}
trap 'restore_files_only; rm -rf "$BACKUP"' EXIT

PASSED=0
FAILED=0

# mutate <file> <find> <replace> — fails loudly if <find> is not present.
mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, find, repl = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if find not in s:
    sys.stderr.write("MUTANT DID NOT APPLY — pattern not found in %s:\n%s\n" % (path, find))
    sys.exit(1)
open(path, "w").write(s.replace(find, repl, 1))
PY
}

expect_red() {
  local name="$1"
  echo "--- mutant: $name"
  if bash tools/ci-p3.sh > "$BACKUP/out.log" 2>&1; then
    echo "    ❌ GATE STAYED GREEN — it does not detect: $name"
    FAILED=$((FAILED + 1))
  else
    echo "    ✅ RED: $(grep -m1 -A2 'P3_CONFORMANCE_FAIL' "$BACKUP/out.log" | tail -1 | head -c 170)"
    PASSED=$((PASSED + 1))
  fi
  restore_files_only
}

echo "=== baseline must be GREEN before any mutant means anything ==="
bash tools/ci-p3.sh > "$BACKUP/base.log" 2>&1 \
  || { echo "BASELINE IS RED — fix that first:"; tail -20 "$BACKUP/base.log"; exit 1; }
echo "    ✅ baseline green"

# M1 — THE P2 BUG, restored. Borders resolve correctly and then every edge is
# painted with the LEFT edge's colour. The box still has a full four-sided
# border of a real colour; three of four edge probes fail and the fourth passes,
# which is the signature of "wrong edge" rather than "no borders".
mutate "$SG" \
  "ImpellerColor c = impellerColor(node.borderColors[e], node.opacity);" \
  "ImpellerColor c = impellerColor(node.borderColors[3], node.opacity);"
expect_red "M1 every border edge painted with the LEFT edge's colour"

# M2 — radii collapse to a single value, i.e. the P2 `borderRadii.all` bug. The
# box is still rounded and still looks deliberate; the three square-corner
# probes are the only thing that can tell one rounded corner from four.
mutate "$SG" \
  "  radii.bottom_left = {node.borderRadii[1], node.borderRadii[1]};" \
  "  radii.bottom_left = {node.borderRadii[0], node.borderRadii[0]};"
mutate "$SG" \
  "  radii.top_right = {node.borderRadii[2], node.borderRadii[2]};" \
  "  radii.top_right = {node.borderRadii[0], node.borderRadii[0]};"
mutate "$SG" \
  "  radii.bottom_right = {node.borderRadii[3], node.borderRadii[3]};" \
  "  radii.bottom_right = {node.borderRadii[0], node.borderRadii[0]};"
expect_red "M2 all four corners get the top-left radius"

# M3 — the ValueUnit trap. RN leaves colour-stop positions UNSET when the author
# did not place them, meaning "distribute evenly"; reading .resolve() blindly
# returns 0 for all of them. The box still paints, in a real colour, with no
# error anywhere — it is just a flat blue instead of a gradient.
#
# NOTE the REAL newlines below. `"\n"` inside a bash double-quoted string is a
# literal backslash-n, so a multi-line pattern written that way never matches —
# the mutate() guard caught exactly that here.
mutate "$SG" \
  "        float pos = (bool)stop.position
                        ? stop.position.resolve(1.0f)
                        : (float)i / (float)(n - 1);" \
  "        float pos = stop.position.resolve(1.0f);"
expect_red "M3 gradient stop positions read blindly (unset stops collapse to 0)"

# M4 — gradient endpoints left in node-local coordinates instead of surface
# coordinates. With clamp tiling the box lands entirely past the gradient's end,
# so it fills with the last stop: a solid, plausible, wrong box.
mutate "$SG" \
  "    ImpellerPoint start = {x + node.gradStart[0], y + node.gradStart[1]};
    ImpellerPoint end = {x + node.gradEnd[0], y + node.gradEnd[1]};" \
  "    ImpellerPoint start = {node.gradStart[0], node.gradStart[1]};
    ImpellerPoint end = {node.gradEnd[0], node.gradEnd[1]};"
expect_red "M4 gradient endpoints not translated into surface coordinates"

# M5 — `transform` ignored. The box is painted, in the right colour, at the
# right place, at the right size. The centre probe passes. ONLY the corner probe
# — a pixel inside the unrotated bounds but outside the rotated diamond — knows.
mutate "$SG" \
  "      node.hasTransform = resolved != react::Transform::Identity();" \
  "      node.hasTransform = false;"
expect_red "M5 transform prop ignored (axis-aligned box, centre probe still green)"

# M6 — numberOfLines dropped in the TextLayoutManager. Both labels render, both
# have ink, both are legible. They are simply both three lines tall, and only
# the height RELATIONSHIP between them can see it.
mutate "$TLM" \
  "    if (paragraphAttributes.maximumNumberOfLines > 0) {" \
  "    if (false) {"
expect_red "M6 numberOfLines ignored during measurement (both labels wrap)"

echo
echo "=== restoring and re-checking baseline ==="
restore_files_only
bash tools/ci-p3.sh > "$BACKUP/final.log" 2>&1 \
  && echo "    ✅ baseline green again" \
  || { echo "    ❌ tree not restored correctly"; tail -20 "$BACKUP/final.log"; exit 1; }

echo
echo "MUTATION SUMMARY: $PASSED/6 mutants caught"
[ "$FAILED" -eq 0 ] || exit 1
echo "P3_MUTATION_VERIFY_PASS"
