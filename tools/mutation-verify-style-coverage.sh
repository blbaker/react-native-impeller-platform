#!/usr/bin/env bash
# Mutation check for tools/ci-style-coverage.sh (and the grid-1 tiles judged by
# tools/ci-style-audit.sh). Each mutant breaks ONE landed fix; the gates must
# FAIL and the FAIL line must NAME the tile that fix landed (a mutant killed
# for the wrong tile proves nothing). Mutants are tagged with their pass id
# (SC01a, SC01b, ...) so tools/style-fix-check.sh can run one pass's set:
#   ONLY=SC01a,SC01b bash tools/mutation-verify-style-coverage.sh
# Sources are restored (and the engine rebuilt) on exit, whatever happens.
#
# Mutant index (keep in step with the blocks below):
#   SC00a  border colour alpha dropped (opaque border)   -> g2:borderAlphaOverBg
#   SC01a  Text paints at the frame origin (insets dropped) -> g2:textBoxStyle
#   SC02a  TextInput paint ignores contentInsets.left -> g2:tiPadding
#   SC03a  width without colour paints nothing -> g2:borderNoColor
#   SC04a  mixed rounded border drops the outer radius clip -> g2:roundedPerSideWidthColor
#   SC04b  mixed rounded border drops the inner cutout -> g2:radiusUnevenWidth
#   SC05a  rounded dashed border falls back to solid -> g2:dashedRounded
#   SC05b  dashed border paints every dash in the top colour -> g2:dashedPerSideColor
#   SC06a  vertical corner radius takes the horizontal one -> g2:ellipticalRadius
#   SC06b  continuous corners fall back to circular -> g2:borderCurve
#   SC07a  backgroundColor skipped when an image layer exists -> g2:gradientOverBgColor
#   SC07b  only one image layer painted -> g2:gradientLayers
#   SC07c  colour hints ignored -> g2:gradientColorHint
#   SC07d  radial gradients painted as linear -> nw:gradientRadial
#   SC08a  backgroundSize ignored (tile = box) -> g2:backgroundSize
#   SC08b  backgroundPosition ignored (offset 0) -> g2:backgroundPosition
#   SC08c  backgroundRepeat ignored (one tile) -> g2:backgroundSize
#   SC09a  outlineOffset ignored -> grid1 outline
#   SC09b  dashed outline painted solid -> g2:outlineDashed
#   SC09c  solid outline stroke twice as wide -> nw:outline
#   SC10a  back-facing test never fires -> nw:backface
#   SC10b  back-facing test inverted -> nw:backface
#   SC11a  filter chain applied in reverse order -> g2:filterChain
#   SC11b  grayscale luma row wrong -> nw:grayscale
#   SC11c  invert drops its offset -> g2:filterInvert
#   SC11d  hue-rotate degrees used as radians -> g2:filterHueRotate
#   SC11e  brightness ignored -> g2:filterChain (grid1 filterBrightness fails too, but the coverage gate reports first)
#   SC11f  filter opacity ignored -> g2:filterOpacity
set -euo pipefail
cd "$(dirname "$0")/.."
# Every file any mutant edits. Add yours here.
FILES=(engine/scenegraph/SceneGraph.cpp engine/scenegraph/Shadows.cpp
       engine/text/TextStyle.h engine/text/ImpellerTextLayoutManager.cpp
       engine/fabric/FabricHost.cpp engine/scenegraph/BorderDash.h)
for f in engine/scenegraph/*.cpp engine/scenegraph/*.h engine/text/*.h engine/text/*.cpp \
         engine/modules/*.h engine/modules/*.cpp engine/host/*.cpp package/src/metro-shims/shims/*.js \
         package/src/metro-shims/index.js; do
  [ -f "$f" ] && FILES+=("$f")
done
BAK="$(mktemp -d)"
for f in "${FILES[@]}"; do mkdir -p "$BAK/$(dirname "$f")"; cp "$f" "$BAK/$f"; done
put_back() { for f in "${FILES[@]}"; do cp "$BAK/$f" "$f"; done; }
restore() {
  put_back
  bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || echo "WARN: rebuild of restored tree failed" >&2
  rm -rf "$BAK"
}
trap restore EXIT
fail() { echo "STYLE_COVERAGE_MUTATION_FAIL: $*" >&2; exit 1; }
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]; }

# Both gates; the FAIL line of whichever fails first is what check() reads.
run_gate() {
  set +e
  { bash tools/ci-style-coverage.sh && bash tools/ci-style-audit.sh; } > "$1" 2>&1
  local rc=$?; set -e; return $rc
}

mutate() {  # FILE OLD NEW: exact replacement, anchor asserted present once
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) == 1, f"mutation anchor not found exactly once in {p}: {old!r}"
open(p, "w").write(s.replace(old, new))
PY
}

# Package (JS) mutants need the probe bundles rebuilt to take effect; such a
# mutant calls `rebundle` after `mutate` (needs node; WSL only).
rebundle() {
  bash tools/build-style-coverage-bundles.sh > "$BAK/rebundle.log" 2>&1 \
    || { tail -5 "$BAK/rebundle.log" >&2; fail "rebundle failed"; }
  REBUNDLED=1
}

check() {  # name, tiles that must be named in the FAIL line
  local name="$1"; shift
  bash tools/engine-build.sh linux x64 > "$BAK/$name.build.log" 2>&1 \
    || { tail -5 "$BAK/$name.build.log" >&2; fail "$name tree did not build"; }
  if run_gate "$BAK/$name.log"; then fail "$name SURVIVED: gates passed with the mutant in"; fi
  local line; line="$(grep -oE 'STYLE_(COVERAGE|AUDIT)_GATE_FAIL: .*' "$BAK/$name.log" | head -1 || true)"
  for t in "$@"; do
    echo "$line" | grep -qF -- "$t" || { tail -6 "$BAK/$name.log" >&2; fail "$name killed, but not for $t: $line"; }
  done
  echo "   OK: $name killed ($line)"
  put_back
  [ -z "${REBUNDLED:-}" ] || { git checkout -- fixtures/*/prebuilt/ 2>/dev/null; REBUNDLED=; }
}

echo "== control: unmutated tree must PASS =="
bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || fail "control tree did not build"
run_gate "$BAK/control.log" || { tail -8 "$BAK/control.log" >&2; fail "control FAILED: nothing below means anything"; }
echo "   OK: control passes"
N=0

# ---- mutants (append new blocks at the end; keep blocks UNINDENTED so
# multi-line anchors match the source byte for byte) ----

if want SC00a; then
echo "== SC00a: border colour alpha dropped =="
mutate engine/scenegraph/SceneGraph.cpp "      if (colors[i]) colorToFloats(colors[i], node.borderColors[i]);" "      if (colors[i]) { colorToFloats(colors[i], node.borderColors[i]); node.borderColors[i][3] = 1.0f; }"
check SC00a g2:borderAlphaOverBg; N=$((N + 1))
fi

if want SC01a; then
echo "== SC01a: Text paints at the frame origin =="
mutate engine/scenegraph/SceneGraph.cpp "const float px = x + (float)pins.left, py = y + (float)pins.top;" "const float px = x, py = y;"
check SC01a g2:textBoxStyle; N=$((N + 1))
fi

if want SC02a; then
echo "== SC02a: TextInput paints at the default pad only =="
mutate engine/scenegraph/SceneGraph.cpp "return kTextInputPad + (float)node.layoutMetrics.contentInsets.left;" "return kTextInputPad;"
check SC02a g2:tiPadding; N=$((N + 1))
fi

if want SC03a; then
echo "== SC03a: width without colour paints nothing =="
mutate engine/scenegraph/SceneGraph.cpp "node.hasBorderColors[i] = (bool)colors[i] || widths[i] > 0;" "node.hasBorderColors[i] = (bool)colors[i];"
check SC03a g2:borderNoColor; N=$((N + 1))
fi

if want SC04a; then
echo "== SC04a: mixed rounded border without the outer radius clip =="
mutate engine/scenegraph/BorderRounded.cpp "ImpellerDisplayListBuilderClipRoundedRect(builder, &outer, &radii,
                                            kImpellerClipOperationIntersect);" "(void)radii;"
check SC04a g2:roundedPerSideWidthColor; N=$((N + 1))
fi

if want SC04b; then
echo "== SC04b: mixed rounded border thickness ignores the per-edge width =="
mutate engine/scenegraph/BorderRounded.cpp "const float t = widths[0], r = widths[1], b = widths[2], l = widths[3];" "const float t = widths[3], r = widths[3], b = widths[3], l = widths[3];"
check SC04b g2:radiusUnevenWidth; N=$((N + 1))
fi

if want SC05a; then
echo "== SC05a: rounded dashed border falls back to solid =="
mutate engine/scenegraph/SceneGraph.cpp "(rounded || !uniformColor)) {" "(!uniformColor)) {"
check SC05a g2:dashedRounded; N=$((N + 1))
fi

if want SC05b; then
echo "== SC05b: dashed border paints every dash in the top colour =="
mutate engine/scenegraph/BorderDashRounded.cpp "ImpellerColor c = colors[side];" "ImpellerColor c = colors[0];"
check SC05b g2:dashedPerSideColor; N=$((N + 1))
fi

if want SC06a; then
echo "== SC06a: vertical corner radius takes the horizontal one =="
mutate engine/scenegraph/SceneGraph.cpp "radii.top_left = {node.borderRadii[0], node.borderRadiiV[0]};" "radii.top_left = {node.borderRadii[0], node.borderRadii[0]};"
mutate engine/scenegraph/SceneGraph.cpp "radii.bottom_left = {node.borderRadii[1], node.borderRadiiV[1]};" "radii.bottom_left = {node.borderRadii[1], node.borderRadii[1]};"
mutate engine/scenegraph/SceneGraph.cpp "radii.top_right = {node.borderRadii[2], node.borderRadiiV[2]};" "radii.top_right = {node.borderRadii[2], node.borderRadii[2]};"
mutate engine/scenegraph/SceneGraph.cpp "radii.bottom_right = {node.borderRadii[3], node.borderRadiiV[3]};" "radii.bottom_right = {node.borderRadii[3], node.borderRadii[3]};"
check SC06a g2:ellipticalRadius; N=$((N + 1))
fi

if want SC06b; then
echo "== SC06b: continuous corners fall back to circular =="
mutate engine/scenegraph/SceneGraph.cpp "const bool continuous = rounded && node.borderContinuous;" "const bool continuous = false && rounded && node.borderContinuous;"
check SC06b g2:borderCurve; N=$((N + 1))
fi

if want SC07a; then
echo "== SC07a: backgroundColor skipped when an image layer exists =="
mutate engine/scenegraph/SceneGraph.cpp "  // CSS order: background colour first, then every image layer over it.
  if (node.hasBackgroundColor && node.bg[3] > 0.0f) {" "  // CSS order: background colour first, then every image layer over it.
  if (node.bgLayers.empty() && node.hasBackgroundColor && node.bg[3] > 0.0f) {"
check SC07a g2:gradientOverBgColor; N=$((N + 1))
fi

if want SC07b; then
echo "== SC07b: only one image layer painted =="
mutate engine/scenegraph/BackgroundLayers.cpp "for (auto it = layers.rbegin(); it != layers.rend(); ++it) {" "for (auto it = layers.rbegin(); it != layers.rbegin() + 1 && it != layers.rend(); ++it) {"
check SC07b g2:gradientLayers; N=$((N + 1))
fi

if want SC07c; then
echo "== SC07c: colour hints ignored =="
mutate engine/scenegraph/BackgroundLayers.cpp "  if (span <= 0.0f) return;" "  if (span <= 0.0f || true) return;"
check SC07c g2:gradientColorHint; N=$((N + 1))
fi

if want SC07d; then
echo "== SC07d: radial gradients painted as linear =="
mutate engine/scenegraph/BackgroundLayers.cpp "    if (it->radial) {" "    if (false && it->radial) {"
check SC07d nw:gradientRadial; N=$((N + 1))
fi

if want SC08a; then
echo "== SC08a: backgroundSize ignored =="
mutate engine/scenegraph/BackgroundTiles.cpp "  t.tw = std::max(t.tw, 1.0f);" "  t.tw = std::max(w, 1.0f);"
check SC08a g2:backgroundSize; N=$((N + 1))
fi

if want SC08b; then
echo "== SC08b: backgroundPosition ignored =="
mutate engine/scenegraph/BackgroundTiles.cpp "  const float ox = AxisOffset(pos.left, pos.right, w, t.tw);" "  const float ox = 0.0f * AxisOffset(pos.left, pos.right, w, t.tw);"
mutate engine/scenegraph/BackgroundTiles.cpp "  const float oy = AxisOffset(pos.top, pos.bottom, h, t.th);" "  const float oy = 0.0f * AxisOffset(pos.top, pos.bottom, h, t.th);"
check SC08b g2:backgroundPosition; N=$((N + 1))
fi

if want SC08c; then
echo "== SC08c: backgroundRepeat ignored =="
mutate engine/scenegraph/BackgroundTiles.cpp "  if (style == S::NoRepeat) {" "  if (style == S::NoRepeat || style == S::Repeat) {"
check SC08c g2:backgroundSize; N=$((N + 1))
fi

if want SC09a; then
echo "== SC09a: outlineOffset ignored =="
mutate engine/scenegraph/Outline.cpp "  const float grow = offset + width;" "  const float grow = 0.0f * offset + width;"
check SC09a outline; N=$((N + 1))
fi

if want SC09b; then
echo "== SC09b: dashed outline painted solid =="
mutate engine/scenegraph/Outline.cpp "  if (style != 0) {" "  if (style != 0 && style > 5) {"
check SC09b g2:outlineDashed; N=$((N + 1))
fi

if want SC09c; then
echo "== SC09c: solid outline stroke twice as wide =="
mutate engine/scenegraph/Outline.cpp "  ImpellerPaintSetStrokeWidth(paint, width);" "  ImpellerPaintSetStrokeWidth(paint, width * 2.0f);"
check SC09c nw:outline; N=$((N + 1))
fi

if want SC10a; then
echo "== SC10a: back-facing test never fires =="
mutate engine/scenegraph/SceneGraph.cpp "        node.backfaceHidden = det < 0;" "        node.backfaceHidden = det < -1e30;"
check SC10a nw:backface; N=$((N + 1))
fi

if want SC10b; then
echo "== SC10b: back-facing test inverted =="
mutate engine/scenegraph/SceneGraph.cpp "        node.backfaceHidden = det < 0;" "        node.backfaceHidden = det > 0;"
check SC10b nw:backface; N=$((N + 1))
fi

if want SC11a; then
echo "== SC11a: filter chain applied in reverse order =="
mutate engine/scenegraph/ColorMatrixFilter.cpp "    total = Then(total, m);" "    total = Then(m, total);"
check SC11a g2:filterChain; N=$((N + 1))
fi

if want SC11b; then
echo "== SC11b: grayscale luma row wrong =="
mutate engine/scenegraph/ColorMatrixFilter.cpp "  return RgbMatrix(0.2126f + 0.7874f * s," "  return RgbMatrix(0.2126f + 0.7874f * s + 0.3f,"
check SC11b nw:grayscale; N=$((N + 1))
fi

if want SC11c; then
echo "== SC11c: invert drops its offset =="
mutate engine/scenegraph/ColorMatrixFilter.cpp "      m = Scale(1.0f - 2.0f * a, a);" "      m = Scale(1.0f - 2.0f * a, 0.0f);"
check SC11c g2:filterInvert; N=$((N + 1))
fi

if want SC11d; then
echo "== SC11d: hue-rotate degrees used as radians =="
mutate engine/scenegraph/ColorMatrixFilter.cpp "  const float r = degrees * 3.14159265358979f / 180.0f;" "  const float r = degrees;"
check SC11d g2:filterHueRotate; N=$((N + 1))
fi

if want SC11e; then
echo "== SC11e: brightness ignored =="
mutate engine/scenegraph/ColorMatrixFilter.cpp "    case FilterType::Brightness: m = Scale(std::max(v, 0.0f), 0.0f); return true;" "    case FilterType::Brightness: m = Scale(1.0f, 0.0f); return true;"
check SC11e g2:filterChain; N=$((N + 1))
fi

if want SC11f; then
echo "== SC11f: filter opacity ignored =="
mutate engine/scenegraph/ColorMatrixFilter.cpp "m[18] = std::clamp(v, 0.0f, 1.0f); return true;" "m[18] = 1.0f; return true;"
check SC11f g2:filterOpacity; N=$((N + 1))
fi

if [ -n "${ONLY:-}" ]; then
  echo "STYLE_COVERAGE_MUTATION_PARTIAL_PASS ($N mutant(s) of ONLY=$ONLY killed for their own tile)"
else
  echo "STYLE_COVERAGE_MUTATION_PASS ($N mutants killed for their own tile)"
fi
