#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-world-resize.sh.
#
# Puts back the pre-fix resize order, one texture cache at a time, rebuilds,
# and proves the gate goes red on ARM PIXEL (the arm aimed at it), not on a
# side effect.
#
# M-world-reuse   paintWorldNode: re-upload into the ADOPTED name, release the
#                 old wrapper afterwards (Impeller deletes the name), re-adopt
#                 the dead name. The exact pre-fix code. Terrain presents black.
# M-sprite-reuse  the same order in paintWorldSprites' atlas cache. The
#                 fixture re-registers 'bubble' 8x8 -> 16x16, so every bubble
#                 presents black after the swap.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC_SCENE="engine/scenegraph/SceneGraph.cpp"

BAK="$(mktemp -d)"
cp "$SRC_SCENE" "$BAK/SceneGraph.cpp"
restore() { cp "$BAK/SceneGraph.cpp" "$SRC_SCENE"; }
trap 'restore; rm -rf "$BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }
grep -q "// MUTANT RESIZE" "$SRC_SCENE" && fail "mutant residue already in the tree -- restore it first (git diff)"

build_or_fail() {
  bash tools/engine-build.sh linux x64 > "$BAK/build-$1.log" 2>&1 \
    || { tail -40 "$BAK/build-$1.log" >&2; fail "$1 tree did not build"; }
}

# mutate FUNC_START OLD NEW -- replace OLD exactly once inside FUNC_START's body.
mutate() {
  python3 - "$SRC_SCENE" "$@" <<'PY'
import sys
path, func, old, new = sys.argv[1:5]
s = open(path).read()
i = s.index(func)
j = s.index("\n}\n", i)
seg = s[i:j]
assert seg.count(old) == 1, f"anchor not found exactly once ({seg.count(old)}): {old[:70]!r}"
open(path, "w").write(s[:i] + seg.replace(old, new, 1) + s[j:])
PY
}

expect_kill() {
  local name="$1"
  build_or_fail "$name"
  set +e
  bash tools/ci-world-resize.sh > "$BAK/$name.log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$name SURVIVED: ci-world-resize.sh passed on the pre-fix resize order."
  grep -q "pixels differ from the oracle by > 6 after the resize" "$BAK/$name.log" || {
    tail -20 "$BAK/$name.log" >&2
    fail "$name failed the gate, but NOT on ARM PIXEL -- killed by a side effect, not the arm aimed at it."
  }
  echo "   $name KILLED by ARM PIXEL: $(grep -o '[0-9]* pixels differ[^(]*(max [0-9]*' "$BAK/$name.log" | head -1)"
  restore
}

echo "== M-world-reuse =="
mutate "bool SceneGraph::paintWorldNode(" \
"    if (cacheEntry.texture) {
      ImpellerTextureRelease(cacheEntry.texture);
      cacheEntry.texture = nullptr;
      cacheEntry.glTex = 0;  // Impeller deletes it; it is no longer ours
    }
    if (cacheEntry.glTex == 0) {" \
"    // MUTANT RESIZE M-world-reuse: pre-fix order, release AFTER the upload
    if (cacheEntry.glTex == 0) {"
mutate "bool SceneGraph::paintWorldNode(" \
"    cacheEntry.uploadedVersion = entry->version;
    ImpellerTextureDescriptor desc" \
"    cacheEntry.uploadedVersion = entry->version;
    if (cacheEntry.texture) {
      ImpellerTextureRelease(cacheEntry.texture);
      cacheEntry.texture = nullptr;
    }
    ImpellerTextureDescriptor desc"
expect_kill M-world-reuse

echo "== M-sprite-reuse =="
mutate "bool SceneGraph::paintWorldSprites(" \
"        if (e.texture) {
          ImpellerTextureRelease(e.texture);
          e.texture = nullptr;
          e.glTex = 0;
        }
        if (e.glTex == 0) {" \
"        // MUTANT RESIZE M-sprite-reuse: pre-fix order, release AFTER the upload
        if (e.glTex == 0) {"
mutate "bool SceneGraph::paintWorldSprites(" \
"        e.uploadedVersion = src->version;
        ImpellerTextureDescriptor desc" \
"        e.uploadedVersion = src->version;
        if (e.texture) {
          ImpellerTextureRelease(e.texture);
          e.texture = nullptr;
        }
        ImpellerTextureDescriptor desc"
expect_kill M-sprite-reuse

echo "== restore + rebuild the real engine =="
restore
build_or_fail restored
bash tools/ci-world-resize.sh > "$BAK/restored.log" 2>&1 || { tail -20 "$BAK/restored.log" >&2; fail "gate is RED on the restored (fixed) engine"; }
echo "   restored engine: $(tail -1 "$BAK/restored.log")"
echo "MUTATION_VERIFY_WORLD_RESIZE_PASS (2/2 killed by ARM PIXEL)"
