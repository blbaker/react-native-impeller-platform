#!/usr/bin/env bash
# ENG-05b: prove tools/ci-path-aa.sh FAILS when the AA it reports is removed.
#   M1 the whole-tree offscreen is allocated at native size (no N x)      -> B
#   M2 the per-<Svg> hook never runs (oversize surfaces lose icon AA)     -> D
#   M3 the per-<Svg> offscreen is sized in points, not device pixels      -> D
#      (the ENG-05b fix: 4 edge levels instead of 16 at --scale 2)
# Not claimed: switching the whole-tree hook OFF. Every shape here is inside
# an <Svg>, so the per-<Svg> hook antialiases it at N=4 either way; that
# mutant survives correctly. The whole-tree hook's own proof is
# ci-supersample-root.sh (a View border, which only it can reach).
# The darwin default (arm C on the Mac) is read from the binary's own
# `supersample_rnsvg=` line, so a flipped __APPLE__ default fails C directly;
# linux cannot compile that branch, so no linux mutant is claimed for it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SG"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
LOG="${MV_LOG_DIR:-$BACKUP}"
restore() { cp "$BACKUP/SG" "$SG"; }
trap 'restore; eval "$BUILD_CMD" > "$LOG/restore.log" 2>&1 || true' EXIT

PASS=0; TOTAL=0
mutate() {  # $1 file  $2 old  $3 new  (exact, must occur exactly once)
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
n = s.count(old)
assert n == 1, f"anchor found {n}x in {p}: {old[:60]!r}"
open(p, "w").write(s.replace(old, new))
PY
}
run_mutant() {  # $1 name  $2 ERE the FAIL line must match
  TOTAL=$((TOTAL + 1))
  echo "--- $1"
  if ! eval "$BUILD_CMD" > "$LOG/build.log" 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' "$LOG/build.log" | head -3 | sed 's/^/     /'
  elif bash tools/ci-path-aa.sh > "$LOG/gate.log" 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "PATH_AA_GATE_FAIL: ($2)" "$LOG/gate.log"; then
    echo "   caught: $(grep PATH_AA_GATE_FAIL "$LOG/gate.log" | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep PATH_AA_GATE_FAIL "$LOG/gate.log" | head -1 | sed 's/^/     /'
  fi
  restore
}

echo "MUTATION_VERIFY_PATH_AA_START"

mutate "$SG" "  const int pxW = nativeW * N;" \
             "  const int pxW = nativeW;  // MUTANT M1"
mutate "$SG" "  const int pxH = nativeH * N;" \
             "  const int pxH = nativeH;  // MUTANT M1"
run_mutant "M1 whole-tree offscreen at native size" "B: "

mutate "$SG" "  if (node.isSvgRoot && supersample_ >= 1 && renderContext_ != nullptr) {" \
             "  if (false && node.isSvgRoot && renderContext_ != nullptr) {  // MUTANT M2"
run_mutant "M2 per-<Svg> hook never runs" "D: "

mutate "$SG" "  const float S = pointScale_ > 0.0f ? pointScale_ : 1.0f;" \
             "  const float S = 1.0f;  // MUTANT M3"
run_mutant "M3 per-<Svg> offscreen sized in points" "D: "

echo "caught $PASS / $TOTAL"
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "PATH_AA_MUTATION_PASS"
else
  echo "PATH_AA_MUTATION_FAIL"
  exit 1
fi
