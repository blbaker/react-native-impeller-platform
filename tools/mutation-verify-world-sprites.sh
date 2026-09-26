#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-world-sprites.sh (ENG-10).
#
# Breaks the real engine one way at a time, rebuilds, and proves the gate goes
# red -- on the ARM that is supposed to catch that mutant, not by accident.
#
# M-order   reverse the draw loop (front-to-back). Killed by ARM B: the fixture
#           overlaps neighbours of DIFFERENT luma, so every overlap strip flips.
# M-atlas   key the atlas GPU cache by texture SIZE instead of textureId (a
#           realistic cache-key bug). peep-light and peep-dark are both 24x24,
#           so one draws as the other. Killed by ARM B. Non-vacuous only
#           because >=2 visually distinct same-size entries are drawn.
# M-flip    copy the FBO-path translate+scale(1,-1) onto each sprite. Killed by
#           ARM B: every atlas entry is vertically asymmetric.
# M-alpha   ignore per-sprite alpha (never build the alpha paint). Killed by
#           ARM B: every 5th sprite is alpha 0.5 over non-flat terrain.
# M-premul  skip premultiplication in registerSprite. Killed by ARM B: the
#           tinted semi-transparent shadow composites too bright.
# M-inert   drawSprites validates but never publishes the list. Killed by
#           ARM A: world_sprites_drawn=0 != list length.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC_MODULE="engine/modules/WorldRasterModule.h"
SRC_SCENE="engine/scenegraph/SceneGraph.cpp"

BAK="$(mktemp -d)"
cp "$SRC_MODULE" "$BAK/WorldRasterModule.h"
cp "$SRC_SCENE" "$BAK/SceneGraph.cpp"
restore() {
  cp "$BAK/WorldRasterModule.h" "$SRC_MODULE"
  cp "$BAK/SceneGraph.cpp" "$SRC_SCENE"
}
trap 'restore; rm -rf "$BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

if grep -q "// MUTANT ENG10" "$SRC_MODULE" "$SRC_SCENE"; then
  fail "mutant residue already in the tree -- restore it before running (git diff)"
fi
grep -q "bool SceneGraph::paintWorldSprites(" "$SRC_SCENE" || fail "paintWorldSprites not present -- nothing to verify"

run_gate() {
  local log="$1"
  set +e
  bash tools/ci-world-sprites.sh > "$log" 2>&1
  local rc=$?
  set -e
  return $rc
}
build_or_fail() {
  bash tools/engine-build.sh linux x64 > "$BAK/build-$1.log" 2>&1 \
    || { tail -40 "$BAK/build-$1.log" >&2; fail "$1 tree did not build"; }
}

# mutate FILE FUNC_START OLD NEW -- replace OLD exactly once, inside the body
# of the function whose definition starts with FUNC_START ("" = whole file).
mutate() {
  python3 - "$@" <<'PY'
import sys
path, func, old, new = sys.argv[1:5]
s = open(path).read()
if func:
    i = s.index(func)
    j = s.index("\n}\n", i)
else:
    i, j = 0, len(s)
seg = s[i:j]
assert seg.count(old) == 1, f"anchor not found exactly once in {path} ({seg.count(old)}): {old[:60]!r}"
open(path, "w").write(s[:i] + seg.replace(old, new, 1) + s[j:])
PY
}

# expect_kill NAME ARM_GREP
expect_kill() {
  local name="$1" pattern="$2"
  build_or_fail "$name"
  if run_gate "$BAK/$name.log"; then
    fail "$name SURVIVED: ci-world-sprites.sh passed on a broken engine."
  fi
  grep -q "$pattern" "$BAK/$name.log" || {
    tail -25 "$BAK/$name.log" >&2
    fail "$name killed, but NOT by the expected arm (/$pattern/). See tail above."
  }
  echo "   OK: $name killed ($(grep -o 'WORLD_SPRITES_GATE_FAIL: .\{0,110\}' "$BAK/$name.log" | head -1))"
  restore
}

PSW="bool SceneGraph::paintWorldSprites("
PIX="pixels differ from the CPU-composite oracle"

echo "== control: unmutated tree must PASS =="
build_or_fail control
run_gate "$BAK/control.log" || { tail -30 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q WORLD_SPRITES_GATE_PASS "$BAK/control.log" || fail "control did not print WORLD_SPRITES_GATE_PASS"
echo "   OK: control passes"

echo "== M-order: draw front-to-back =="
mutate "$SRC_SCENE" "$PSW" \
  "  for (const WorldSprite& s : list->sprites) {" \
  "  // MUTANT ENG10 M-order: reversed paint order.
  for (auto it_ = list->sprites.rbegin(); it_ != list->sprites.rend(); ++it_) {
    const WorldSprite& s = *it_;"
expect_kill M-order "$PIX"

echo "== M-atlas: cache keyed by size, not textureId =="
mutate "$SRC_SCENE" "$PSW" \
  "      WorldTextureEntry& e = spriteTextureCache_[textureId];" \
  "      // MUTANT ENG10 M-atlas: same-size entries collide.
      WorldTextureEntry& e =
          spriteTextureCache_[std::to_string(srcW) + \"x\" + std::to_string(srcH)];"
expect_kill M-atlas "$PIX"

echo "== M-flip: FBO-path Y-flip copied onto sprites =="
mutate "$SRC_SCENE" "$PSW" \
  "    ImpellerRect dstRect = {s.x, s.y, s.w, s.h};" \
  "    // MUTANT ENG10 M-flip: FBO flip on a CPU-uploaded texture.
    ImpellerRect dstRect = {0, 0, s.w, s.h};
    ImpellerDisplayListBuilderSave(builder);
    ImpellerDisplayListBuilderTranslate(builder, s.x, s.y + s.h);
    ImpellerDisplayListBuilderScale(builder, 1.0f, -1.0f);"
mutate "$SRC_SCENE" "$PSW" \
  "    if (alphaPaint) ImpellerPaintRelease(alphaPaint);" \
  "    ImpellerDisplayListBuilderRestore(builder);
    if (alphaPaint) ImpellerPaintRelease(alphaPaint);"
expect_kill M-flip "$PIX"

echo "== M-alpha: per-sprite alpha ignored =="
mutate "$SRC_SCENE" "$PSW" \
  "    if (s.alpha < 1.0f) {" \
  "    if (false && s.alpha < 1.0f) {  // MUTANT ENG10 M-alpha"
expect_kill M-alpha "$PIX"

echo "== M-premul: straight alpha uploaded =="
mutate "$SRC_MODULE" "" \
  "      if (a == 255) continue;" \
  "      if (a == 255 || true) continue;  // MUTANT ENG10 M-premul"
expect_kill M-premul "$PIX"

echo "== M-inert: drawSprites never publishes =="
mutate "$SRC_MODULE" "" \
  "    me.store_->setSprites(id, std::move(sprites));" \
  "    (void)sprites;  // MUTANT ENG10 M-inert"
expect_kill M-inert "world_sprites_drawn=0 != drawSprites list length"

echo "== restore + rebuild =="
restore
trap - EXIT
bash tools/engine-build.sh linux x64 > "$BAK/restore.log" 2>&1 \
  || { tail -40 "$BAK/restore.log" >&2; fail "restored tree did not build"; }
rm -rf "$BAK"
echo "MUTATION_VERIFY_PASS (6/6 killed: M-order, M-atlas, M-flip, M-alpha, M-premul via ARM B pixels; M-inert via ARM A count)"
