#!/usr/bin/env bash
# MUTATION TEST for tools/ci-snapshot.sh (FP-43). Each mutant edits ENGINE
# SOURCE, rebuilds, and must turn the gate red for its own reason.
#
#   M1  Y-flipped readback: glReadPixels' bottom-up rows are returned as is
#       -> the capture is the on-screen crop upside down
#   M2  captures the whole window instead of the subtree: the snapshot walk
#       paints the roots at the node's size -> the window's top-left corner
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN

FILES=(engine/scenegraph/SnapshotReadbackGl.cpp engine/scenegraph/SnapshotRecord.cpp)
BACKUP="$(mktemp -d)"
for f in "${FILES[@]}"; do cp "$f" "$BACKUP/$(basename "$f")"; done
restore() { for f in "${FILES[@]}"; do cp "$BACKUP/$(basename "$f")" "$f"; done; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-snapshot.sh > "$1" 2>&1; }

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
  if grep -q 'SNAPSHOT_PASS' "$2" || ! grep -q 'SNAPSHOT_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-snapshot stayed GREEN" >&2; tail -5 "$2" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 FAIL "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | cut -c1-220)"
}

echo "== M1: Y-flipped readback =="
mutate engine/scenegraph/SnapshotReadbackGl.cpp \
  'raw.data() + (size_t)(h - 1 - y) * row, row);' \
  'raw.data() + (size_t)y * row, row);  // MUTANT M1: rows left bottom-up'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'A: capture is upside down: .* \(Y-flipped readback\)'
restore

echo "== M2: captures the whole window instead of the subtree =="
mutate engine/scenegraph/SnapshotRecord.cpp \
  '    paintNode(b, *node, -(float)f.origin.x, -(float)f.origin.y);' \
  '    for (auto t : roots_) paintNode(b, nodes_.at(t), 0, 0);  // MUTANT M2: the window, not the node'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'A: capture shows the window from \(0,0\), not the view: .* \(whole window captured\)'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(tail -1 "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATION_VERIFY_SNAPSHOT_PASS"
