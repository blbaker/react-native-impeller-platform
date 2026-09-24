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
# mutant's binary proves nothing). The default build is engine-build.sh, which
# restages the linux package; on a box that has node the gate renders the
# committed prebuilt bundle with that freshly-staged binary.
#
# ⛔ NO-NPM MODE (the Mac): engine-build.sh calls `node -p` and dies on the Mac's
#   node-less ssh. Pass a cmake-direct build + RNI_BIN so the gate renders with
#   the cmake build tree binary and the committed bundle — no npm, no node:
#     RNI_BUILD_CMD='/opt/homebrew/bin/cmake --build engine/build --target rn-impeller -j8' \
#     RNI_BIN=engine/build/rn-impeller  bash tools/mutation-verify-supersample.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable-timeout.sh"  # portable timeout (mac fallback)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SceneGraph.cpp"

# The command that rebuilds the engine between mutants. Default is
# engine-build.sh (WSL/dev boxes); the Mac overrides with a cmake-direct build.
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh}"

trap 'cp "$BACKUP/SceneGraph.cpp" "$SG"; eval "$BUILD_CMD" > /tmp/mss-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

PASS=0
TOTAL=0

run_mutant() {
  local name="$1"
  TOTAL=$((TOTAL + 1))
  echo "--- mutant: $name ---"
  if ! eval "$BUILD_CMD" > /tmp/mss-build.log 2>&1; then
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
  eval "$BUILD_CMD" > /tmp/mss-rebuild.log 2>&1 || true
}

echo "MUTATION_VERIFY_SUPERSAMPLE_START"

# M1: force the ROOT offscreen to NATIVE resolution regardless of N. Step 4
# measures the AA jump on the N=4 arm, which goes through paintTreeSupersampled
# (the per-icon hook is suppressed at N>=2), so the AA mutant MUST target the
# root path's pixel size, not the per-icon path's. With no upscale the downsample
# has nothing to average and the edge stays binary -> the partial/luma jump
# vanishes -> gate fails. (Per-icon AA is separately covered at N=1 by the count
# arm and by ci-supersample-root.sh's own mutation script for View borders.)
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

# M2: skip the ROOT composite DrawTextureRect. The whole-tree offscreen renders
# but is never drawn back into the main builder, so the frame is blank -> the N=4
# ink floor fails. Proves the composite is real and the AA is not measured off a
# stale in-place frame.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
# Anchor the WHOLE-TREE root composite in paintTreeSupersampled (Translate-by-
# nativeH is unique to it) — the earlier bare-DrawTextureRect anchor matched TWO
# call sites and replace(,1) hit the SVG-root composite instead. (04:34 audit.)
old="""  ImpellerRect srcRect = {0, 0, (float)texW, (float)texH};
  ImpellerRect dstRect = {0, 0, (float)nativeW, (float)nativeH};
  ImpellerDisplayListBuilderSave(builder);
  ImpellerDisplayListBuilderTranslate(builder, 0, (float)nativeH);
  ImpellerDisplayListBuilderScale(builder, 1.0f, -1.0f);
  ImpellerDisplayListBuilderDrawTextureRect(builder, texture, &srcRect, &dstRect,
                                            kImpellerTextureSamplingLinear,
                                            nullptr);
  ImpellerDisplayListBuilderRestore(builder);"""
new="""  (void)texW; (void)texH; (void)nativeW; (void)nativeH;  // MUTANT M2: whole-tree root composite skipped, tree blank"""
assert s.count(old)==1, "M2 anchor not unique/found"
open(p,"w").write(s.replace(old,new,1))
PY
run_mutant "M2 whole-tree root composite DrawTextureRect skipped (tree blank)"

# A: drop the painted_ = savedPainted restore in the per-icon offscreen walk.
# On a cache MISS the inner paintNode walk then LEAKS its ++painted_ increments
# into the live counter, so painted_nodes at N=1 (the per-icon path) exceeds N=0
# and the node_frame line count. Proves the 3b cache-independence arm is real and
# not fooled by the root-supersample path (which suppresses this hook at N>=2).
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
old="""    supersample_ = savedN;
    painted_ = savedPainted;"""
new="""    supersample_ = savedN;
    (void)savedPainted;  // MUTANT A: offscreen walk leaks ++painted_ on a MISS"""
assert old in s, "A anchor not found"
open(p,"w").write(s.replace(old,new,1))
PY
run_mutant "A per-icon offscreen walk leaks painted_ on a cache MISS (N=1 > N=0)"

# B: drop the cache-independent subtree attribution at the supersample hook. The
# offscreen inner walk is counter-suppressed and (on a HIT) never runs at all, so
# without this line the icon's subtree is NEVER counted -> painted_nodes at N=1
# under-counts vs N=0 and vs node_frame lines. This is the exact task-768
# regression the old `--painted_;` shipped (N=0=534 vs N=4=531 on a repeated icon).
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
old="      painted_ += countPaintedNodes(node, svgUseDepth_) - 1;"
new="      (void)0;  // MUTANT B: subtree never attributed -> under-count on hit/miss"
assert old in s, "B anchor not found"
open(p,"w").write(s.replace(old,new,1))
PY
run_mutant "B supersample hook drops subtree attribution (N=1 < N=0, task-768)"

# ── PER-ICON POSITION-GATE MUTANTS (tools/ci-supersample-position.sh) ────────
# These run the POSITION gate, not ci-supersample.sh. run_mutant above greps for
# SUPERSAMPLE_GATE_{PASS,FAIL} (the AA gate); the position gate emits
# SUPERSAMPLE_POSITION_GATE_{PASS,FAIL}, so drive it with a dedicated runner.
run_pos_mutant() {
  local name="$1"
  TOTAL=$((TOTAL + 1))
  echo "--- mutant: $name ---"
  if ! eval "$BUILD_CMD" > /tmp/mss-build.log 2>&1; then
    echo "  BUILD FAILED -- a mutant that does not compile proves nothing"
    grep -E "error:" /tmp/mss-build.log | head -3 | sed 's/^/     /'
  elif timeout 600 bash tools/ci-supersample-position.sh > /tmp/mss-pos.log 2>&1; then
    echo "  ⛔ NOT CAUGHT -- position gate still passed"
    grep -E "SUPERSAMPLE_POSITION_GATE_PASS" /tmp/mss-pos.log | tail -1 | sed 's/^/     /'
  else
    echo "  caught:"
    grep -E "SUPERSAMPLE_POSITION_GATE_FAIL" /tmp/mss-pos.log | head -2 | sed 's/^/     /'
    PASS=$((PASS + 1))
  fi
  cp "$BACKUP/SceneGraph.cpp" "$SG"
  eval "$BUILD_CMD" > /tmp/mss-rebuild.log 2>&1 || true
}

# C: skip the PER-ICON composite DrawTextureRect. This is THE bug this whole fix
# repairs: paintSvgRootSupersampled builds and caches the texture, returns true
# (so paintNode skips the in-place walk), but never draws it — every per-icon
# <Svg> paints NOTHING. The per-icon arm's ink-presence assertion (within 10% of
# N=0) MUST fail at N=1 (and N=8). Proves the per-icon composite is load-bearing.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
old="""  ImpellerDisplayListBuilderDrawTextureRect(builder, texture, &srcRect, &dstRect,
                                            kImpellerTextureSamplingLinear,
                                            nullptr);
  ImpellerDisplayListBuilderRestore(builder);
  // ⛔ DO NOT RELEASE `texture` HERE. The host draws `builder`'s display list
  // AFTER paint() returns, and it references this texture. Unlike the root path"""
new="""  (void)srcRect; (void)dstRect;  // MUTANT C: per-icon composite skipped -> icon vanishes
  ImpellerDisplayListBuilderRestore(builder);
  // ⛔ DO NOT RELEASE `texture` HERE. The host draws `builder`'s display list
  // AFTER paint() returns, and it references this texture. Unlike the root path"""
assert old in s, "C anchor not found"
open(p,"w").write(s.replace(old,new,1))
PY
run_pos_mutant "C per-icon composite DrawTextureRect skipped (icons vanish at N=1/N=8)"

# D: drop the Y-flip on the PER-ICON composite. The wrapped-FBO texture is
# bottom-left origin; without the flip each up-arrow composites as a down-arrow.
# The per-icon arm's orientation assertion (each arrow base-heavy) MUST fail.
python3 - <<'PY'
p="engine/scenegraph/SceneGraph.cpp"; s=open(p).read()
old="""  ImpellerDisplayListBuilderSave(builder);
  ImpellerDisplayListBuilderTranslate(builder, x, y + h);
  ImpellerDisplayListBuilderScale(builder, 1.0f, -1.0f);
  ImpellerDisplayListBuilderDrawTextureRect(builder, texture, &srcRect, &dstRect,
                                            kImpellerTextureSamplingLinear,
                                            nullptr);
  ImpellerDisplayListBuilderRestore(builder);"""
new="""  ImpellerDisplayListBuilderSave(builder);
  ImpellerDisplayListBuilderTranslate(builder, x, y);  // MUTANT D: no Y-flip -> mirrored
  ImpellerDisplayListBuilderDrawTextureRect(builder, texture, &srcRect, &dstRect,
                                            kImpellerTextureSamplingLinear,
                                            nullptr);
  ImpellerDisplayListBuilderRestore(builder);"""
assert old in s, "D anchor not found"
open(p,"w").write(s.replace(old,new,1))
PY
run_pos_mutant "D per-icon composite Y-flip dropped (up-arrows composite as down-arrows)"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_SUPERSAMPLE_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_SUPERSAMPLE_FAIL ($PASS/$TOTAL)"
  exit 1
fi
