#!/usr/bin/env bash
# MUTATION TEST for tools/ci-gl-validation.sh (FP-05). Each mutant edits engine source, rebuilds,
# and must turn the gate red for its own reason; the source is restored and the clean engine
# re-gated at the end.
#
#   M1  the bad glBindTexture runs on frame 2 of every run (not only under the test hook)
#       -> arm A reports gl_validation_errors>=1 on a clean fixture
#   M2  the raster-side texture upload (TextureUploaderGl, used by <world> setPixels since FP-14)
#       passes a depth format to glTexImage2D
#       -> arm A reports gl_validation_errors>=1 on Eng21Nearest
#   M3  the KHR_debug callback stops counting errors -> arm B sees the planted error uncounted
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GV="engine/base/GlValidation.cpp"
SG="engine/scenegraph/TextureUploaderGl.cpp"
BACKUP="$(mktemp -d)"
cp "$GV" "$BACKUP/GlValidation.cpp"
cp "$SG" "$BACKUP/TextureUploaderGl.cpp"
restore() { cp "$BACKUP/GlValidation.cpp" "$GV"; cp "$BACKUP/TextureUploaderGl.cpp" "$SG"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-gl-validation.sh > "$1" 2>&1; }

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
  if ! grep -q 'GL_VALIDATION_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-gl-validation stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-160)"
}

echo "== M1: bad bind on frame 2 of every run =="
mutate "$GV" 'if (frame == 2 && hook && !std::strcmp(hook, "1") && gBindTexture) {' \
  'if (frame == 2 && gBindTexture) {  // MUTANT M1'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'GL_VALIDATION_FAIL: A (window|headless) NativeRotateProbe: gl_validation_errors=[1-9]'
restore

echo "== M2: depth format in the world-raster upload =="
mutate "$SG" '    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, j.w, j.h, 0, GL_RGBA, GL_UNSIGNED_BYTE, j.rgba);' \
'    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, j.w, j.h, 0, GL_DEPTH_COMPONENT, GL_UNSIGNED_BYTE, j.rgba);  // MUTANT M2'
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'GL_VALIDATION_FAIL: A (window|headless) Eng21Nearest: gl_validation_errors=[1-9]'
restore

echo "== M3: callback does not count errors =="
mutate "$GV" '  if (isError) gErrors.fetch_add(1, std::memory_order_relaxed);' \
  '  if (isError && false) gErrors.fetch_add(1, std::memory_order_relaxed);  // MUTANT M3'
build "$BACKUP/m3-build.log"; gate "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" 'GL_VALIDATION_FAIL: B (window|headless): planted glBindTexture error not counted'
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(grep -o 'GL_VALIDATION_PASS.*' "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_GL_VALIDATION_OK -- 3 mutants, 3 killed, engine restored and green"
