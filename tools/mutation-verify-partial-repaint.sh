#!/usr/bin/env bash
# MUTATION TEST for tools/ci-partial-repaint.sh (FP-18). Each mutant edits ENGINE
# SOURCE, rebuilds, and must turn the gate red for its own reason.
#
#   M1  the damage misses the old position (only the changed node's NEW box is
#       damaged): the box leaves a ghost trail -> A: partial frames differ from
#       the same frame repainted in full
#   M2  the 0.7 ratio check is inverted (partial only when the damage is LARGE)
#       -> A: the spinner's small damage repaints the whole surface
#   M3  the partial blit lands at device rows instead of GL rows (no Y flip)
#       -> A: partial frames differ from the full repaint
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN

DT="engine/scenegraph/DamageTracker.cpp"
PR="engine/host/PartialRepaintGl.cpp"
BACKUP="$(mktemp -d)"
cp "$DT" "$BACKUP/DamageTracker.cpp"
cp "$PR" "$BACKUP/PartialRepaint.cpp"
restore() { cp "$BACKUP/DamageTracker.cpp" "$DT"; cp "$BACKUP/PartialRepaint.cpp" "$PR"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-partial-repaint.sh > "$1" 2>&1; }

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
  if grep -q 'PARTIAL_REPAINT_PASS' "$2" || ! grep -q 'PARTIAL_REPAINT_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-partial-repaint stayed GREEN" >&2; tail -5 "$2" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 -E 'FAIL|^[ABC]:' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-220)"
}

echo "== M1: damage misses the old position (ghost trail) =="
mutate "$DT" '    for (int tag : marked_) addTag(find(cur_, tag), find(prev_, tag));' \
'    for (int tag : marked_) addTag(find(cur_, tag), nullptr);  // MUTANT M1: new box only'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" '^A: [0-9]+ partial frames differ from the full repaint'
restore

echo "== M2: the 0.7 ratio check inverted =="
mutate "$DT" '  return rx <= kImpellerRepaintRatio || ry <= kImpellerRepaintRatio;' \
'  return !(rx <= kImpellerRepaintRatio || ry <= kImpellerRepaintRatio);  // MUTANT M2'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" '^A: (no partial frame in|a steady frame repainted)'
restore

echo "== M3: partial blit without the GL row flip =="
mutate "$PR" '    const int y0 = H - d.y - d.h, y1 = H - d.y;  // GL rows of the damage' \
'    const int y0 = d.y, y1 = d.y + d.h;  // MUTANT M3: device rows'
build "$BACKUP/m3-build.log"; gate "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" '^A: [0-9]+ partial frames differ from the full repaint'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(tail -1 "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_PARTIAL_REPAINT_OK -- 3 mutants, 3 killed, engine restored and green"
