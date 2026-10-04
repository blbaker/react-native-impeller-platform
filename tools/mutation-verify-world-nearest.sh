#!/usr/bin/env bash
# ENG-21: prove tools/ci-world-nearest.sh FAILS when any one piece of the fix is
# removed. Each mutant edits the live tree, rebuilds, runs the gate, restores.
#   M1 terrain (setPixels) path ignores the sampler     -> arm A
#   M2 sprite path ignores the sampler                  -> arm A
#   M3 the store never records setSampling              -> arm A
#   M4 an unknown mode no longer throws                 -> arm C
#   M5 every world samples nearest (default changed)    -> arm B
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SG="engine/scenegraph/SceneGraph.cpp"
ST="engine/modules/WorldRasterStore.h"
MOD="engine/modules/WorldRasterModule.h"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SG"; cp "$ST" "$BACKUP/ST"; cp "$MOD" "$BACKUP/MOD"
BUILD_CMD="${RNI_BUILD_CMD:-bash tools/engine-build.sh linux x64}"
restore() { cp "$BACKUP/SG" "$SG"; cp "$BACKUP/ST" "$ST"; cp "$BACKUP/MOD" "$MOD"; }
trap 'restore; eval "$BUILD_CMD" > /tmp/mvwn-restore.log 2>&1 || true; rm -rf "$BACKUP"' EXIT

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
  if ! eval "$BUILD_CMD" > /tmp/mvwn-build.log 2>&1; then
    echo "   BUILD FAILED: a mutant that does not compile proves nothing"
    grep -E 'error:' /tmp/mvwn-build.log | head -3 | sed 's/^/     /'
  elif bash tools/ci-world-nearest.sh > /tmp/mvwn-gate.log 2>&1; then
    echo "   NOT CAUGHT: gate still passed"
  elif grep -qE "WORLD_NEAREST_GATE_FAIL: ($2):" /tmp/mvwn-gate.log; then
    echo "   caught: $(grep WORLD_NEAREST_GATE_FAIL /tmp/mvwn-gate.log | head -1 | cut -c1-170)"
    PASS=$((PASS + 1))
  else
    echo "   killed, but not by the expected arm ($2):"
    grep WORLD_NEAREST_GATE_FAIL /tmp/mvwn-gate.log | head -1 | sed 's/^/     /'
  fi
  restore
}

echo "MUTATION_VERIFY_WORLD_NEAREST_START"

mutate "$SG" "                                            worldSampling(node),  // ENG-21" \
             "                                            kImpellerTextureSamplingLinear,  // MUTANT M1"
run_mutant "M1 terrain path ignores the sampler" "A"

mutate "$SG" "  const ImpellerTextureSampling sampling = worldSampling(node);" \
             "  const ImpellerTextureSampling sampling = kImpellerTextureSamplingLinear;  // MUTANT M2"
run_mutant "M2 sprite path ignores the sampler" "A"

mutate "$ST" "      nearest_[id] = nearest;" "      (void)nearest;  // MUTANT M3"
run_mutant "M3 store never records setSampling" "A"

mutate "$MOD" '    } else if (mode != "linear") {' '    } else if (false) {  // MUTANT M4'
run_mutant "M4 unknown mode does not throw" "C"

mutate "$SG" "             ? kImpellerTextureSamplingNearestNeighbor
             : kImpellerTextureSamplingLinear;" \
             "             ? kImpellerTextureSamplingNearestNeighbor
             : kImpellerTextureSamplingNearestNeighbor;  // MUTANT M5"
run_mutant "M5 every world samples nearest" "B"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_WORLD_NEAREST_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_WORLD_NEAREST_FAIL ($PASS/$TOTAL)"
  exit 1
fi
