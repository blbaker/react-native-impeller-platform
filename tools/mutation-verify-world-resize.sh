#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-world-resize.sh.
#
# Puts back the pre-fix resize order, one texture cache at a time, rebuilds,
# and proves the gate goes red on ARM PIXEL (the arm aimed at it), not on a
# side effect.
#
# M-reuse  FP-20 retarget: the world and sprite caches share the GL name
#          uploader (scenegraph/TextureUploaderGl.cpp), so one mutant puts back
#          the pre-fix order there: on a resize, release the old wrapper
#          (Impeller now deletes the name) and re-adopt the SAME name instead
#          of a fresh one. Terrain and the re-registered 'bubble' sprite
#          (8x8 -> 16x16) present black after the swap.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC_SCENE="engine/scenegraph/TextureUploaderGl.cpp"

BAK="$(mktemp -d)"
cp "$SRC_SCENE" "$BAK/TextureUploaderGl.cpp"
restore() { cp "$BAK/TextureUploaderGl.cpp" "$SRC_SCENE"; }
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

echo "== M-reuse =="
mutate "  bool Upload(TextureSlot& slot, RasterJobs* jobs," \
"      slot.texture = nullptr;
      slot.handle = 0;
      uint32_t name = 0;
      slot.texture = WrapNewGlName(ctx_, *pool_, w, h, &name);" \
"      slot.texture = nullptr;
      // MUTANT RESIZE M-reuse: re-adopt the released (dead) name on a resize
      uint32_t name = (uint32_t)slot.handle;
      slot.handle = 0;
      if (name != 0) {
        ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888, {w, h}, 1};
        slot.texture = ImpellerTextureCreateWithOpenGLTextureHandleNew(ctx_, &desc, name);
      } else {
        slot.texture = WrapNewGlName(ctx_, *pool_, w, h, &name);
      }"
expect_kill M-reuse

echo "== restore + rebuild the real engine =="
restore
build_or_fail restored
bash tools/ci-world-resize.sh > "$BAK/restored.log" 2>&1 || { tail -20 "$BAK/restored.log" >&2; fail "gate is RED on the restored (fixed) engine"; }
echo "   restored engine: $(tail -1 "$BAK/restored.log")"
echo "MUTATION_VERIFY_WORLD_RESIZE_PASS (1/1 killed by ARM PIXEL)"
