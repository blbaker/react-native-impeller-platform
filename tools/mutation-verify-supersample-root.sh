#!/usr/bin/env bash
# Mutation verification for tools/ci-supersample-root.sh (ENG item 2b).
#
# Proves the gate measures the ROOT SUPERSAMPLE, not merely "an offscreen ran"
# and not merely "some ink was drawn". Three mutants, each defeating one of the
# gate's assertions:
#
#   M1  force the whole-tree offscreen to NATIVE resolution (the "N=1" control
#       expressed at the root): the offscreen round-trip and the composite both
#       run, but with no upscale there is nothing for the downsample to average,
#       so the corner stays binary. The N=1->N=4 luma/partial jump MUST vanish
#       -> gate fails. This is the load-bearing mutant: it proves the gate is not
#       fooled by "an offscreen ran".
#   M2  skip the final composite DrawTextureRect: the tree renders offscreen but
#       is never drawn back, so the frame VANISHES. The gate's ink floor on the
#       N=4 arm MUST fail -> gate fails. Proves the composite is real.
#   M3  route N=1 through the root offscreen too (change the paint() guard from
#       >=2 to >=1): now the BASELINE antialiases, so the matched-pair negative
#       (N=1 must stay a flat step) MUST fail -> gate fails. Proves the gate
#       actually checks that the baseline is binary, not just that N=4 is high.
#
# ⛔ REBUILD BETWEEN MUTANTS (a mutant scored against the prior mutant's binary
#   proves nothing) and REBUILD THE PREBUILT BUNDLE IS NOT NEEDED — the fixture
#   JS is unchanged; only the engine changes. The gate renders the committed
#   bundle with the freshly-built binary, so a rebuilt engine reaches the gate.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable-timeout.sh"  # portable timeout (mac fallback)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SceneGraph.cpp"
trap 'cp "$BACKUP/SceneGraph.cpp" "$SG"; eval "${RNI_BUILD_CMD:-bash tools/engine-build.sh}" > /tmp/msr-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

PASS=0
TOTAL=0

# The command that rebuilds the engine between mutants. Default is
# engine-build.sh (WSL/dev boxes). ⛔ THE MAC HAS NO node, so engine-build.sh
# fails at `node -p` — the Mac passes a cmake-direct build instead, e.g.
#   RNI_BUILD_CMD='/opt/homebrew/bin/cmake --build engine/build --target rn-impeller -j8' \
#   RNI_BIN=engine/build/rn-impeller  bash tools/mutation-verify-supersample-root.sh
# When RNI_BIN points at the cmake build tree, ci-supersample-root.sh renders
# with that binary directly (no npm, no staged package).
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh}"

run_mutant() {
  local name="$1"
  TOTAL=$((TOTAL + 1))
  echo "--- mutant: $name ---"
  if ! eval "$BUILD_CMD" > /tmp/msr-build.log 2>&1; then
    echo "  BUILD FAILED -- a mutant that does not compile proves nothing"
    grep -E "error:" /tmp/msr-build.log | head -3 | sed 's/^/     /'
  elif timeout 300 bash tools/ci-supersample-root.sh > /tmp/msr-gate.log 2>&1; then
    echo "  ⛔ NOT CAUGHT -- gate still passed"
    grep -E "SUPERSAMPLE_ROOT_GATE_PASS" /tmp/msr-gate.log | sed 's/^/     /'
  else
    echo "  caught:"
    grep -E "SUPERSAMPLE_ROOT_GATE_FAIL" /tmp/msr-gate.log | head -2 | sed 's/^/     /'
    PASS=$((PASS + 1))
  fi
  cp "$BACKUP/SceneGraph.cpp" "$SG"
  eval "$BUILD_CMD" > /tmp/msr-rebuild.log 2>&1 || true
}

echo "MUTATION_VERIFY_SUPERSAMPLE_ROOT_START"

# M1: render the whole-tree offscreen at NATIVE resolution regardless of N. The
# offscreen FBO still runs and composites, but with no upscale the downsample has
# nothing to average, so the corner stays binary — the design's N=1 control
# expressed as a root-path code mutation.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
old="""  const int pxW = nativeW * N;
  const int pxH = nativeH * N;"""
new="""  const int pxW = nativeW;  // MUTANT M1: root offscreen at native res (no supersample)
  const int pxH = nativeH;  // MUTANT M1"""
assert old in s, "M1 anchor not found"
open(p,"w").write(s.replace(old,new,1))
PY
run_mutant "M1 root offscreen forced to native resolution (no supersample, no AA)"

# M2: skip the final composite. The tree renders offscreen and is held in
# treeTexture_, but never drawn into the main builder -- paintTreeSupersampled
# still returns true, so paint() skips the in-place walk and the frame vanishes.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
old="""  ImpellerRect srcRect = {0, 0, (float)texW, (float)texH};
  ImpellerRect dstRect = {0, 0, (float)nativeW, (float)nativeH};
  ImpellerDisplayListBuilderSave(builder);
  ImpellerDisplayListBuilderTranslate(builder, 0, (float)nativeH);
  ImpellerDisplayListBuilderScale(builder, 1.0f, -1.0f);
  ImpellerDisplayListBuilderDrawTextureRect(builder, texture, &srcRect, &dstRect,
                                            kImpellerTextureSamplingLinear,
                                            nullptr);
  ImpellerDisplayListBuilderRestore(builder);"""
new="""  (void)texW; (void)texH; (void)nativeW; (void)nativeH;  // MUTANT M2: composite skipped, frame vanishes"""
assert s.count(old)==1, "M2 anchor not unique/found"
open(p,"w").write(s.replace(old,new,1))
PY
run_mutant "M2 root composite DrawTextureRect skipped (frame vanishes)"

# M3: make the BASELINE (N=1) actually supersample, by (a) letting N=1 take the
# root path and (b) forcing the internal factor to 4 regardless of the flag. Now
# N=1 antialiases the corner, so the gate's matched-pair NEGATIVE (N=1 must be a
# flat ~2-level step) MUST fail. Proves the gate checks the baseline is binary,
# not just that N=4 is high — without that check a build that always antialiased
# would pass, defeating the whole "Impeller doesn't AA this" premise.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
old="  if (supersample_ >= 2 && paintTreeSupersampled(builder, pointScaleFactor)) {"
new="  if (supersample_ >= 1 && paintTreeSupersampled(builder, pointScaleFactor)) {  // MUTANT M3: N=1 also enters"
assert old in s, "M3 anchor not found"
old2="""  const int N = supersample_;
  if (N < 2 || renderContext_ == nullptr) return false;      // <2 = in-place/mutant"""
new2="""  const int N = supersample_ < 1 ? 0 : 4;  // MUTANT M3: force 4x even at N=1
  if (N < 1 || renderContext_ == nullptr) return false;      // MUTANT M3"""
assert old2 in s, "M3 anchor 2 not found"
s=s.replace(old,new,1).replace(old2,new2,1)
open(p,"w").write(s)
PY
run_mutant "M3 N=1 forced to real 4x supersample (baseline no longer flat)"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_SUPERSAMPLE_ROOT_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_SUPERSAMPLE_ROOT_FAIL ($PASS/$TOTAL)"
  exit 1
fi
