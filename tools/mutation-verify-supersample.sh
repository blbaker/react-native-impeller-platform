#!/usr/bin/env bash
# Mutation verification for tools/ci-supersample.sh (ENG item 2).
#
# Proves the gate measures the SUPERSAMPLE, not merely "an offscreen was used"
# and not merely "some ink was drawn". Two mutants, each defeating one of the
# gate's two assertions:
#
#   M1  force the offscreen to NATIVE resolution (the design's "N=1" control):
#       an offscreen round-trip happens, but with no supersampling there is no
#       box-filter AA, so the edge stays binary. The gate's partial-pixel /
#       luma-level jump MUST vanish -> gate fails. This is the load-bearing
#       mutant: it proves the gate is not fooled by "an offscreen ran".
#   M2  skip the final composite DrawTextureRect: the offscreen renders but is
#       never drawn back, so the icon VANISHES. The gate's ink floor on the N=4
#       arm MUST fail -> gate fails. Proves the composite is real.
#
# Restore by cp and REBUILD between mutants (a mutant scored against the prior
# mutant's binary proves nothing). engine-build.sh restages the package the gate
# reinstalls, so each mutant reaches the gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SceneGraph.cpp"
trap 'cp "$BACKUP/SceneGraph.cpp" "$SG"; bash tools/engine-build.sh > /tmp/mss-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

PASS=0
TOTAL=0

run_mutant() {
  local name="$1"
  TOTAL=$((TOTAL + 1))
  echo "--- mutant: $name ---"
  if ! bash tools/engine-build.sh > /tmp/mss-build.log 2>&1; then
    echo "  BUILD FAILED -- a mutant that does not compile proves nothing"
    grep -E "error:" /tmp/mss-build.log | head -3 | sed 's/^/     /'
  elif timeout 600 bash tools/ci-supersample.sh > /tmp/mss-gate.log 2>&1; then
    echo "  ⛔ NOT CAUGHT -- gate still passed"
    grep -E "SUPERSAMPLE_GATE_PASS" /tmp/mss-gate.log | sed 's/^/     /'
  else
    echo "  caught:"
    grep -E "SUPERSAMPLE_GATE_FAIL" /tmp/mss-gate.log | head -2 | sed 's/^/     /'
    PASS=$((PASS + 1))
  fi
  cp "$BACKUP/SceneGraph.cpp" "$SG"
  bash tools/engine-build.sh > /tmp/mss-rebuild.log 2>&1 || true
}

echo "MUTATION_VERIFY_SUPERSAMPLE_START"

# M1: render the offscreen at NATIVE resolution regardless of N. The offscreen
# FBO still runs (the composite path is exercised), but with no upscale there is
# nothing for the downsample to average, so the edge stays binary. This is the
# design's N=1 control expressed as a code mutation.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
old="""  const int pxW = (int)std::ceil(w * (float)N);
  const int pxH = (int)std::ceil(h * (float)N);"""
new="""  const int pxW = nativeW;  // MUTANT M1: offscreen at native res (no supersample)
  const int pxH = nativeH;  // MUTANT M1"""
assert old in s, "M1 anchor not found"
open(p,"w").write(s.replace(old,new,1))
PY
run_mutant "M1 offscreen forced to native resolution (no supersample, no AA)"

# M2: skip the final composite. The offscreen is rendered and cached, but never
# drawn into the main builder -- the function still returns true, so paintNode
# skips the in-place walk and the icon vanishes entirely.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
old="""  ImpellerDisplayListBuilderDrawTextureRect(builder, texture, &srcRect, &dstRect,
                                            kImpellerTextureSamplingLinear,
                                            nullptr);
  return true;"""
new="""  (void)srcRect; (void)dstRect;  // MUTANT M2: composite skipped, icon vanishes
  return true;"""
assert old in s, "M2 anchor not found"
open(p,"w").write(s.replace(old,new,1))
PY
run_mutant "M2 final composite DrawTextureRect skipped (icon vanishes)"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_SUPERSAMPLE_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_SUPERSAMPLE_FAIL ($PASS/$TOTAL)"
  exit 1
fi
