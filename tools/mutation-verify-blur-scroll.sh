#!/usr/bin/env bash
# MUTATION TEST for tools/ci-blur-scroll.sh (FP-41 readback damage). Each mutant
# edits ENGINE SOURCE, rebuilds, and must turn the gate red for its own reason.
#
#   M1  no readback: the BlurView never registers what it reads (the pre-fix
#       engine), so a partial frame blurs a blank scratch outside the damage and
#       leaves the rest of the header showing the old tile -> "S: tile: header
#       above the tile" (stale vs the reference)
#   M2  readback reach 0: the read area is the blur's own box, so the header's
#       lower edge samples the blank scratch below it -> "V: ... partial frames
#       differ" (the engine's own partial-vs-full compare)
#   M3  readback never joins (JoinReadbacks a no-op) -> same as M1, via the join
# Plus a gate-side check that P can fail: with the window loop's partial
# repaint forced off the tile run has no partial frames -> "P: ...".
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SG="engine/scenegraph/SceneGraph.cpp"
DT="engine/scenegraph/DamageTracker.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SceneGraph.cpp"
cp "$DT" "$BACKUP/DamageTracker.cpp"
restore() { cp "$BACKUP/SceneGraph.cpp" "$SG"; cp "$BACKUP/DamageTracker.cpp" "$DT"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT
build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { RNI_BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller" bash tools/ci-blur-scroll.sh > "$1" 2>&1; }
mutate() {  # file old new
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
n = s.count(old)
assert n == 1, "anchor found %dx in %s" % (n, p)
open(p, "w").write(s.replace(old, new, 1))
PY
}
expect_killed() {  # name log ERE
  if ! grep -q 'BLUR_SCROLL_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-blur-scroll stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m4 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-200)"
}

echo "== M1: no readback recorded =="
mutate "$SG" '    damage_.RecordReadback(builder, node.tag, ImpellerRect{x, y, w, h}, reach, unbounded);' \
  '    (void)reach;  // MUTANT M1: the blur never registers what it reads'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'FAIL S: tile: header above the tile'
restore

echo "== M2: readback reach 0 =="
mutate "$SG" '    const float reach = 3.0f * rni::BlurSigmaForIntensity(node.blurIntensity) + 2.0f;' \
  '    const float reach = 0.0f;  // MUTANT M2: read only the blur'"'"'s own box'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'FAIL V: [0-9]+ of [0-9]+ partial frames differ'
restore

echo "== M3: readbacks never join the damage =="
mutate "$DT" '  if (!full) full = JoinReadbacks(&d);  // FP-41: blurs over the damage' \
  '  // MUTANT M3: if (!full) full = JoinReadbacks(&d);'
build "$BACKUP/m3-build.log"; gate "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" 'FAIL S: tile: header above the tile'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(grep -o 'BLUR_SCROLL_PASS' "$BACKUP/final.log")"

echo "== G1 (gate side): partial repaint off -> P must fail =="
RNI_BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller" BLUR_SCROLL_EXTRA_FLAGS="--partial-repaint off" \
  bash tools/ci-blur-scroll.sh > "$BACKUP/g1.log" 2>&1 || true
expect_killed G1 "$BACKUP/g1.log" 'FAIL P: the tile run repainted only 0 frames partially'
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_BLUR_SCROLL_OK -- 3 engine mutants + 1 gate check, all killed, engine restored and green"
