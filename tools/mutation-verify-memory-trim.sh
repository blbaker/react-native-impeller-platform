#!/usr/bin/env bash
# MUTATION TEST for tools/ci-memory-trim.sh. Each mutant edits ENGINE SOURCE,
# rebuilds linux-x64, and must turn its arm red for its OWN reason.
#
#   M1  arena cap that lies: Configure still prints ok=1 but never sets
#       M_ARENA_MAX -> glibc grows an arena per thread (video arm: arenas=)
#   M2  no trim after the player goes (video arm: no mem_trim naming video)
#   M3  recycler that drops every returned buffer: each frame allocates again
#       (video arm: frame buffers vs frames shown)
#   M4  no prune of removed texture nodes: the GPU upload stays (prune arm)
#
# Restores with cp + touch (never cp -p: an old mtime makes ninja skip the
# rebuild and the mutant stays linked in), rebuilds, and re-runs the gate GREEN.
# Do not run while another build (e.g. linux arm64) reads this source tree.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN
FILES=(engine/base/MemTrim.cpp engine/video/FfmpegPlayer.h engine/scenegraph/FrameRecycler.h engine/scenegraph/SceneGraph.cpp)
BACKUP="$(mktemp -d "${TMPDIR:-/tmp}/mv-memory-trim.XXXXXX")"
for f in "${FILES[@]}"; do mkdir -p "$BACKUP/orig/$(dirname "$f")"; cp "$f" "$BACKUP/orig/$f"; done
restore() { for f in "${FILES[@]}"; do cp "$BACKUP/orig/$f" "$f"; touch "$f"; done; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh linux x64)" >&2' EXIT
build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { ARMS="$1" bash tools/ci-memory-trim.sh > "$2" 2>&1; }
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
  if grep -q 'MEMORY_TRIM_GATE_PASS' "$2" || ! grep -q 'MEMORY_TRIM_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- the gate stayed GREEN" >&2; tail -5 "$2" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 FAIL "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | cut -c1-220)"
}

echo "== M1: arena cap reported but not set =="
mutate engine/base/MemTrim.cpp 'const bool ok = mallopt(M_ARENA_MAX, kArenaMax) == 1 &&' \
       'const bool ok = /* MUTANT M1 */ true &&'
build "$BACKUP/m1-build.log"; gate video "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'MEMORY_TRIM_FAIL: video: arenas=[0-9]+ with arena_max=4'
restore

echo "== M2: no trim after the player is destroyed =="
mutate engine/video/FfmpegPlayer.h '    memtrim::Request("video");' '    /* MUTANT M2 */'
build "$BACKUP/m2-build.log"; gate video "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'MEMORY_TRIM_FAIL: video: no mem_trim naming `video`'
restore

echo "== M3: recycler drops every returned buffer =="
mutate engine/scenegraph/FrameRecycler.h '    if (free_.size() < keep_) free_.push_back(std::move(b));' \
       '    (void)b;  // MUTANT M3'
build "$BACKUP/m3-build.log"; gate video "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" 'MEMORY_TRIM_FAIL: video: [0-9]+ frame buffers for [0-9]+ frames: frames are not recycled'
restore

echo "== M4: removed texture nodes keep their GPU upload =="
mutate engine/scenegraph/SceneGraph.cpp '  if (!cullActive_) pruneExternalTexturesLocked();' '  /* MUTANT M4 */'
build "$BACKUP/m4-build.log"; gate prune "$BACKUP/m4.log" || true
expect_killed M4 "$BACKUP/m4.log" 'MEMORY_TRIM_FAIL: prune: no ext_texture_prune after the unmount'
restore

echo "== restored source: rebuild, the gate must be GREEN again =="
build "$BACKUP/final-build.log"
gate "video control prune" "$BACKUP/final.log" || { tail -8 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate red after restore" >&2; exit 1; }
grep -q 'MEMORY_TRIM_GATE_PASS' "$BACKUP/final.log" || { echo "MUTATE_FAIL: no PASS after restore" >&2; exit 1; }
for f in "${FILES[@]}"; do cmp -s "$BACKUP/orig/$f" "$f" || { echo "MUTATE_FAIL: $f differs after restore" >&2; exit 1; }; done
trap - EXIT
rm -rf "$BACKUP"
echo "MEMORY_TRIM_MUTATION_PASS (4/4 mutants killed, restored source green)"
