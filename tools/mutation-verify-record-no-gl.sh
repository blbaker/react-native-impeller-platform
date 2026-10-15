#!/usr/bin/env bash
# MUTATION TEST for tools/ci-record-no-gl.sh (FP-14). Each mutant edits ENGINE
# SOURCE, rebuilds, and must turn the gate red for its own reason.
#
#   M1  the whole-tree supersample offscreen renders inside RECORD again (its
#       raster job is run on the spot) -> R: GL calls inside RECORD at ss 4
#   M2  an <Image> texture is created inside RECORD again
#       (ImpellerTextureCreateWithContentsNew, whose GLES reactor uploads on
#       the calling thread) -> R: GL calls inside RECORD at ss 0
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN RNI_REF_BIN RECORD_NO_GL_WRITE_GOLDEN RECORD_NO_GL_ONLY

SG="engine/scenegraph/SceneGraph.cpp"
IP="engine/scenegraph/ImagePaint.cpp"
BACKUP="$(mktemp -d)"
cp "$SG" "$BACKUP/SceneGraph.cpp"
cp "$IP" "$BACKUP/ImagePaint.cpp"
restore() { cp "$BACKUP/SceneGraph.cpp" "$SG"; cp "$BACKUP/ImagePaint.cpp" "$IP"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-record-no-gl.sh > "$1" 2>&1; }

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
  if grep -q 'RECORD_NO_GL PASS' "$2" || ! grep -q 'RECORD_NO_GL FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-record-no-gl stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-200)"
}

echo "== M1: the root supersample offscreen renders inside RECORD =="
mutate "$SG" '
  jobs_->AddOffscreen(dl, pxW, pxH, hops, name, texture);
' '
  {  // MUTANT M1: run the root offscreen job on the spot, inside RECORD
    RasterJobs now(renderContext_, namePool_);
    now.AddOffscreen(dl, pxW, pxH, hops, name, texture);
    now.Run();
  }
'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'RECORD_NO_GL FAIL R [a-z-]+-ss4: [1-9][0-9]* GL calls inside RECORD'
restore

echo "== M2: an image texture is created inside RECORD =="
mutate "$IP" '    if (d && context && jobs) {' \
'    if (d && context && jobs && false) {  // MUTANT M2: upload in RECORD'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'RECORD_NO_GL FAIL R (grid|images)-ss0: [1-9][0-9]* GL calls inside RECORD'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(tail -1 "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_RECORD_NO_GL_OK -- 2 mutants, 2 killed, engine restored and green"
