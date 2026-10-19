#!/usr/bin/env bash
# MUTATION TEST for tools/ci-unit.sh (FP-50). Each mutant edits ENGINE SOURCE (the painter), and
# ci-unit.sh rebuilds rni-scenegraph-tests and must go red on the case written for that defect.
#
#   M1  the opacity save-layer is dropped (UsesOpacityLayer never true): opacity 0.5 paints its subtree
#       straight onto the parent -> "FAIL opacity_half_wraps_the_subtree_in_one_save_layer"
#   M2  the overflow clip is taken before the Save that should scope it, so it leaks to later siblings
#       -> "FAIL clip_is_set_before_the_children_draw"
#   M3  the top-left and top-right corner radii are swapped -> "FAIL per_corner_radii_keep_their_corners"
#   M4  the engine's HostPlatformColor.h packs rgba(0,0,0,0) to 0 again (the producer change reverted,
#       with its static_assert), so `transparent` reads as unset and the fallbacks paint black
#       -> every transparent_* case fails, the border edge first
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="engine/scenegraph/SceneGraph.cpp"
HDR="engine/fabric/platform/impeller/react/renderer/graphics/HostPlatformColor.h"
BACKUP="$(mktemp -d)"
cp "$SRC" "$BACKUP/SceneGraph.cpp"
cp "$HDR" "$BACKUP/HostPlatformColor.h"
restore() { cp "$BACKUP/SceneGraph.cpp" "$SRC"; cp "$BACKUP/HostPlatformColor.h" "$HDR"; }
trap 'restore; echo "(engine source restored)" >&2' EXIT

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
gate() { bash tools/ci-unit.sh > "$1" 2>&1; }
expect_killed() {  # name log ERE
  if ! grep -q 'UNIT_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-unit stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m5 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-200)"
}

echo "== M1: opacity save-layer dropped =="
mutate "$SRC" '  const bool opacityLayer = UsesOpacityLayer(node) && !shadowPass;' \
  '  const bool opacityLayer = false && UsesOpacityLayer(node) && !shadowPass;  // MUTANT M1'
gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" '^FAIL opacity_half_wraps_the_subtree_in_one_save_layer'
restore

echo "== M2: clip taken before its Save =="
mutate "$SRC" '  if (clip) {
    pvPushClipLocked(builder, x, y, w, h);  // FP-44 kClipRect mutator
    ImpellerDisplayListBuilderSave(builder);
    // Style audit item 13' '  if (clip) {
    pvPushClipLocked(builder, x, y, w, h);  // FP-44 kClipRect mutator
    // MUTANT M2: the Save moves below the clip
    // Style audit item 13'
mutate "$SRC" '                                         kImpellerClipOperationIntersect);
    }
  }
  // <ScrollView>. ENG-02.' '                                         kImpellerClipOperationIntersect);
    }
    ImpellerDisplayListBuilderSave(builder);
  }
  // <ScrollView>. ENG-02.'
gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" '^FAIL clip_is_set_before_the_children_draw'
restore

echo "== M3: top-left and top-right radii swapped =="
mutate "$SRC" '  radii.top_left = {node.borderRadii[0], node.borderRadiiV[0]};' \
  '  radii.top_left = {node.borderRadii[2], node.borderRadiiV[2]};  // MUTANT M3'
mutate "$SRC" '  radii.top_right = {node.borderRadii[2], node.borderRadiiV[2]};' \
  '  radii.top_right = {node.borderRadii[0], node.borderRadiiV[0]};  // MUTANT M3'
gate "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" '^FAIL per_corner_radii_keep_their_corners'
restore

echo "== M4: transparent packs to the unset colour again =="
mutate "$HDR" '  return color == HostPlatformColor::UndefinedColor ? kTransparentColor : color;
}

static_assert(
    hostPlatformColorFromRGBA(0, 0, 0, 0) != HostPlatformColor::UndefinedColor,
    "a transparent colour must not equal the unset colour");' '  return color;  // MUTANT M4
}'
gate "$BACKUP/m4.log" || true
expect_killed M4 "$BACKUP/m4.log" '^FAIL transparent_border_edge_paints_nothing'
for c in transparent_outline_paints_nothing transparent_ios_shadow_paints_nothing \
         transparent_box_shadow_paints_nothing transparent_drop_shadow_paints_nothing; do
  grep -q "^FAIL $c\$" "$BACKUP/m4.log" || { echo "MUTATE_FAIL: M4 left $c green" >&2; exit 1; }
done
echo "   M4 also failed the outline, iOS shadow, boxShadow and dropShadow cases"
restore

echo "== RESTORE: clean painter must be GREEN =="
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: ci-unit RED after restore" >&2; exit 1; }
echo "   $(grep -o 'UNIT_PASS.*' "$BACKUP/final.log")"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_UNIT_OK -- 4 mutants, 4 killed, painter restored and green"
