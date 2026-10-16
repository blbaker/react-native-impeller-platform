#!/usr/bin/env bash
# MUTATION TEST for tools/ci-external-texture.sh (FP-42). Each mutant edits ENGINE
# SOURCE, rebuilds, and must turn the gate red for its own reason.
#
#   M1  mutator stack not applied: the texture paints before the node's
#       transform/opacity (the <world> early-out shape) -> marker top-left
#   M2  opacity dropped: the texture paints at alpha 1 -> opaque marker
#   M3  stale frame never replaced (registry): MarkFrameAvailable no longer drops
#       the cached frame -> RECORD draws an old seq while newer ones were marked
#   M4  stale frame never replaced (painter): the upload is skipped while the slot
#       is not stale, so the GPU keeps frame 1 -> pixels show another frame than drawn
#   M5  unregister does not wake a frame -> no present after unregister (idle-skip)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN

FILES=(engine/scenegraph/SceneGraph.cpp engine/scenegraph/TextureRegistry.cpp engine/scenegraph/ExternalTexturePaint.cpp)
BACKUP="$(mktemp -d)"
for f in "${FILES[@]}"; do cp "$f" "$BACKUP/$(basename "$f")"; done
restore() { for f in "${FILES[@]}"; do cp "$BACKUP/$(basename "$f")" "$f"; done; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-external-texture.sh > "$1" 2>&1; }

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
  if grep -q 'EXTERNAL_TEXTURE_PASS' "$2" || ! grep -q 'EXTERNAL_TEXTURE_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-external-texture stayed GREEN" >&2; tail -5 "$2" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 FAIL "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | cut -c1-220)"
}

HOOK='  if (node.isExternalTexture) paintExternalTexture(builder, node, x, y, w, h, OwnAlpha(node));'

echo "== M1: mutator stack not applied (paint before transform/opacity) =="
mutate engine/scenegraph/SceneGraph.cpp "$HOOK" '  // MUTANT M1: hook moved before the transform'
mutate engine/scenegraph/SceneGraph.cpp '  if (node.backfaceHidden) return;' '  if (node.isExternalTexture) {  // MUTANT M1
    paintExternalTexture(builder, node, x, y, w, h, 1.0f);
    return;
  }
  if (node.backfaceHidden) return;'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'A: present [0-9]+: the blue marker is top-LEFT .* \(rotate not applied\)'
restore

echo "== M2: opacity dropped =="
mutate engine/scenegraph/SceneGraph.cpp "$HOOK" '  if (node.isExternalTexture) paintExternalTexture(builder, node, x, y, w, h, 1.0f);  // MUTANT M2'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'A: present [0-9]+: marker .* is opaque, wanted 0.6 over white \(opacity not applied\)'
restore

echo "== M3: MarkFrameAvailable keeps the cached frame =="
mutate engine/scenegraph/TextureRegistry.cpp '    it->second.dirty = true;  // embedder MarkNewFrameAvailable: last_image_ = nullptr' '    (void)0;  // MUTANT M3: the cached frame is never dropped'
build "$BACKUP/m3-build.log"; gate "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" 'A: present [0-9]+ drew seq [0-9]+ but [0-9]+ frames were marked available \(stale frame\)'
restore

echo "== M4: painter never re-uploads a live slot =="
mutate engine/scenegraph/ExternalTexturePaint.cpp 'if (SlotStale(e.slot, f.width, f.height) || e.uploadedVersion != f.seq) {' 'if (SlotStale(e.slot, f.width, f.height)) {  // MUTANT M4'
build "$BACKUP/m4-build.log"; gate "$BACKUP/m4.log" || true
expect_killed M4 "$BACKUP/m4.log" 'A: present [0-9]+ shows frame [0-9]+, RECORD drew seq [0-9]+ \(wrong frame\)'
restore

echo "== M5: unregister does not wake a frame =="
mutate engine/scenegraph/TextureRegistry.cpp '  Notify();                // the next frame paints without it' '  // MUTANT M5: no wake on unregister'
build "$BACKUP/m5-build.log"; gate "$BACKUP/m5.log" || true
expect_killed M5 "$BACKUP/m5.log" 'A: no present after unregister \(unregister did not repaint\)'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(tail -1 "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATION_VERIFY_EXTERNAL_TEXTURE_PASS"
