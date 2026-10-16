#!/usr/bin/env bash
# MUTATION TEST for tools/ci-record-raster.sh (FP-13). Each mutant edits ENGINE
# SOURCE, rebuilds, and must turn the gate red for its own reason.
#
#   M1  one-frame lag: RasterFrame draws the PREVIOUS FrameItem's display list
#       (the first frame draws its own) -> P pixels differ on the animated
#       native-transform captures
#   M2  RECORD skips the last child of every node in the paint walk
#       -> P pixels differ on the style grid
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN RNI_REF_BIN RECORD_RASTER_WRITE_GOLDEN

FI="engine/host/FrameItem.cpp"
SG="engine/scenegraph/SceneGraph.cpp"
BACKUP="$(mktemp -d)"
cp "$FI" "$BACKUP/FrameItem.cpp"
cp "$SG" "$BACKUP/SceneGraph.cpp"
restore() { cp "$BACKUP/FrameItem.cpp" "$FI"; cp "$BACKUP/SceneGraph.cpp" "$SG"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-record-raster.sh > "$1" 2>&1; }

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
  if grep -q 'RECORD_RASTER PASS' "$2" || ! grep -q 'RECORD_RASTER FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-record-raster stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-200)"
}

echo "== M1: raster draws the previous FrameItem (one-frame lag) =="
mutate "$FI" '    ok = draw(item.displayList);' \
'    static ImpellerDisplayList prevDl = nullptr;  // MUTANT M1
    ok = draw(prevDl ? prevDl : item.displayList);
    if (prevDl) ImpellerDisplayListRelease(prevDl);
    ImpellerDisplayListRetain(item.displayList);
    prevDl = item.displayList;'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'RECORD_RASTER FAIL P pixels differ: ntx'
restore

echo "== M2: RECORD skips the last child =="
mutate "$SG" '  for (auto childTag : node.children) {
    auto it = nodes_.find(childTag);
    if (it != nodes_.end()) {
      paintNode(builder, it->second, childOriginX, childOriginY);' \
'  for (size_t ci = 0; ci + 1 < node.children.size(); ++ci) {  // MUTANT M2
    auto childTag = node.children[ci];
    auto it = nodes_.find(childTag);
    if (it != nodes_.end()) {
      paintNode(builder, it->second, childOriginX, childOriginY);'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'RECORD_RASTER FAIL P pixels differ: grid-ss0'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(tail -1 "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_RECORD_RASTER_OK -- 2 mutants, 2 killed, engine restored and green"
