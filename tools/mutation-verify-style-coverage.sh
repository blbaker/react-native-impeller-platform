#!/usr/bin/env bash
# Mutation check for tools/ci-style-coverage.sh (and the grid-1 tiles judged by
# tools/ci-style-audit.sh). Each mutant breaks ONE landed fix; the gates must
# FAIL and the FAIL line must NAME the tile that fix landed (a mutant killed
# for the wrong tile proves nothing). Mutants are tagged with their pass id
# (SC01a, SC01b, ...) so one pass's set can run on its own:
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
#   SC12a  blur() not applied -> nw:blur (grid1 filterBlur fails too, the coverage gate reports first)
#   SC12b  iOS shadow on a bare view shadows the whole box again -> g2:shadowNoBg
#   SC12c  content shadow offset ignored -> g2:shadowNoBg
#   SC12d  drop-shadow blur dropped -> filterDropShadow (grid 1; no coverage tile uses drop-shadow)
#   SC12e  content shadow not tinted (a copy of the content) -> g2:shadowNoBg
#   SC13a  multiply composited as normal -> mixBlendMode (grid 1)
#   SC13b  isolation:isolate ignored -> isolation (grid 1)
#   SC14a  italic not applied at paint -> g2:nestedItalic
#   SC14b  nested span opacity ignored -> g2:nestedOpacity
#   SC14c  writingDirection ignored -> writingDirection (grid 1)
#   SC14d  justify painted as left -> textAlignJustify (grid 1)
#   SC14e  vertical centring ignored -> g2:textAlignVertical (also verticalAlign)
#   SC15a  shadow offset ignored -> g2:textShadowNested
#   SC15b  shadow blur ignored -> g2:textShadowNested
#   SC15c  shadow x offset mirrored to -x -> g2:textShadowNested
#   SC16a  head ellipsis cut at the tail -> ellipsizeHead (grid 1)
#   SC16b  middle ellipsis cut at the tail -> ellipsizeMiddle (grid 1)
#   SC17a  painter ignores the fit scale -> g2:adjustsFontSize
#   SC17b  fit search always returns the minimum scale -> g2:adjustsFontSize (measure-only height is invisible to ink rules)
#   SC18a  generic family names not mapped (monospace passes through) -> g2:fontMonospace
#   SC18b  stack takes its first entry without checking it resolves -> g2:fontStack
#   SC19a  no per-glyph fallback (missing glyphs paint tofu) -> risky:cjk
#   SC19b  Arabic block skipped by the fallback lookup (tofu) -> risky:arabic
#   SC20a  TextInput fontWeight ignored -> g2:tiBold
#   SC20b  TextInput fontStyle ignored -> g2:tiItalic
#   SC20c  right alignment shifted like centre -> g2:tiAlignRight
#   SC20d  textAlign centre never shifts the line -> g2:tiAlignCenter
#   SC20e  TextInput decoration line dropped -> g2:tiDecoration
#   SC20f  TextInput textTransform not applied -> g2:tiTextTransform
#   SC22a  PlatformColor names resolve to transparent -> risky:platformColor
#   SC22b  systemBlue table entry wrong -> risky:platformColor
#   SC24a  Button shim fills the block with `color` (android look) -> g2:button
#   SC24b  Button shim ignores `color` for the title -> g2:button
#   SC25a  hover feature flag defaults to false again -> interact:hover
#   SC27a  scroll indicators never painted -> g2:scrollIndicator
#   SC27b  indicator length ignores viewport/content -> g2:scrollIndicator
#   SC27c  contentOffset.y ignored -> scrollContentOffset (grid 1)
#   SC27d  contentOffset.x ignored -> scrollHorizontal (grid 1)
#   SC28a  spokes do not fade -> activityIndicator (grid 1)
#   SC28b  colour prop ignored (iOS gray) -> activityIndicator (grid 1)
#   SC30a  image never painted -> g2:imageBackground
#   SC30b  tintColor ignored -> imageTint (grid 1)
#   SC30c  cover scales like contain -> g2:imageCover
#   SC30d  image not clipped to a square box -> g2:imageCover
#   SC30e  image not clipped to the rounded box -> g2:imageRadius
#   SC30f  contain stretched -> g2:imageContain
#   SC30g  center scales up like contain -> g2:imageCenter
#   SC30h  repeat stretched -> g2:imageRepeat
#   SC32a..g  custom Impeller SDK: no tile, judged by tools/ci-impeller-sdk-custom.sh
#   SC33a..e  letterSpacing (Text paint/measure, TextInput) and fontVariant (smcp, pnum)
#             (tools/mutation-verify-impeller-sdk-custom.sh has the per-mutant rules)
#   SC34a..c  inline View: no paint placeholder, frames not read back, box hung below the baseline
#   SC35a..b  custom SDK on darwin/win: judged by ci-impeller-sdk-custom.sh --all-platforms
set -euo pipefail
cd "$(dirname "$0")/.."
# Every file any mutant edits. Add yours here.
FILES=(engine/fabric/platform/impeller/PlatformColorTable.cpp engine/scenegraph/SceneGraph.cpp engine/scenegraph/Shadows.cpp
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

if want SC12a; then
echo "== SC12a: blur() not applied =="
mutate engine/scenegraph/SceneGraph.cpp "    if (ImpellerImageFilter bf = rni::MakeBlurImageFilter(node.blurSigma)) {" "    if (ImpellerImageFilter bf = rni::MakeBlurImageFilter(0.0f)) {"
check SC12a nw:blur; N=$((N + 1))
fi

if want SC12b; then
echo "== SC12b: iOS shadow on a bare view shadows the whole box again =="
mutate engine/scenegraph/SceneGraph.cpp "  if (node.hasLayerShadow && HasVisibleBackground(node)) {" "  if (node.hasLayerShadow) {"
mutate engine/scenegraph/SceneGraph.cpp "  if (node.hasLayerShadow && !HasVisibleBackground(node)) specs.push_back(node.layerShadow);" ""
check SC12b g2:shadowNoBg; N=$((N + 1))
fi

if want SC12c; then
echo "== SC12c: content shadow offset ignored =="
mutate engine/scenegraph/ContentFilters.cpp "  ImpellerDisplayListBuilderTranslate(builder, s.offsetX, s.offsetY);" "  ImpellerDisplayListBuilderTranslate(builder, 0.0f, 0.0f);"
check SC12c g2:shadowNoBg; N=$((N + 1))
fi

if want SC12d; then
echo "== SC12d: drop-shadow blur dropped =="
mutate engine/scenegraph/ContentFilters.cpp "      s.sigma = std::max(0.0f, static_cast<float>(p.standardDeviation)) * 0.5f;" "      s.sigma = 0.0f;"
check SC12d filterDropShadow; N=$((N + 1))
fi

if want SC12e; then
echo "== SC12e: content shadow not tinted =="
mutate engine/scenegraph/ContentFilters.cpp "ImpellerColorFilterCreateBlendNew(&tint, kImpellerBlendModeSourceIn);" "ImpellerColorFilterCreateBlendNew(&tint, kImpellerBlendModeDestination);"
check SC12e g2:shadowNoBg; N=$((N + 1))
fi

if want SC13a; then
echo "== SC13a: multiply composited as normal =="
mutate engine/scenegraph/BlendGroup.cpp "    case BlendMode::Multiply: return kImpellerBlendModeMultiply;" "    case BlendMode::Multiply: return kImpellerBlendModeSourceOver;"
check SC13a mixBlendMode; N=$((N + 1))
fi

if want SC13b; then
echo "== SC13b: isolation:isolate ignored =="
mutate engine/scenegraph/SceneGraph.cpp "(node.mixBlend != react::BlendMode::Normal || node.isolate);" "(node.mixBlend != react::BlendMode::Normal);"
check SC13b isolation; N=$((N + 1))
fi

if want SC14a; then
echo "== SC14a: italic not applied at paint =="
mutate engine/scenegraph/SceneGraph.cpp "    ApplyFontStyle(style, run.italic);" ""
check SC14a g2:nestedItalic; N=$((N + 1))
fi

if want SC14b; then
echo "== SC14b: nested span opacity ignored =="
mutate engine/scenegraph/SceneGraph.cpp "ImpellerColor tc = impellerColor(run.color, OwnAlpha(node) * run.opacity);" "ImpellerColor tc = impellerColor(run.color, OwnAlpha(node));"
check SC14b g2:nestedOpacity; N=$((N + 1))
fi

if want SC14c; then
echo "== SC14c: writingDirection ignored =="
mutate engine/scenegraph/SceneGraph.cpp "    ApplyTextDirection(style, node.writingDirection);" ""
check SC14c writingDirection; N=$((N + 1))
fi

if want SC14d; then
echo "== SC14d: justify painted as left =="
mutate engine/text/TextStyle.h "    case 4: a = kImpellerTextAlignmentJustify; break;" "    case 4: a = kImpellerTextAlignmentLeft; break;"
check SC14d textAlignJustify; N=$((N + 1))
fi

if want SC14e; then
echo "== SC14e: vertical centring ignored =="
mutate engine/scenegraph/SceneGraph.cpp "  if (node.textVAlign == 3) return spare * 0.5f;" "  if (node.textVAlign == 3) return 0.0f;"
check SC14e g2:textAlignVertical; N=$((N + 1))
fi

if want SC15a; then
echo "== SC15a: textShadow offset ignored =="
mutate engine/scenegraph/SceneGraph.cpp "    spec.offsetX = r.shadowOffX;
    spec.offsetY = r.shadowOffY;" "    spec.offsetX = 0.0f;
    spec.offsetY = 0.0f;"
check SC15a g2:textShadowNested; N=$((N + 1))
fi

if want SC15b; then
echo "== SC15b: textShadow blur ignored =="
mutate engine/scenegraph/SceneGraph.cpp "    spec.sigma = r.shadowSigma;" "    spec.sigma = 0.0f;"
check SC15b g2:textShadowNested; N=$((N + 1))
fi

if want SC15c; then
echo "== SC15c: textShadow x offset mirrored =="
mutate engine/scenegraph/SceneGraph.cpp "    spec.offsetX = r.shadowOffX;" "    spec.offsetX = -r.shadowOffX;"
check SC15c g2:textShadowNested; N=$((N + 1))
fi

if want SC16a; then
echo "== SC16a: head ellipsis cut at the tail =="
mutate engine/scenegraph/EllipsizeText.cpp "const size_t head = mode == 1 ? 0 : (keep + 1) / 2;" "const size_t head = mode == 1 ? keep : (keep + 1) / 2;"
check SC16a ellipsizeHead; N=$((N + 1))
fi

if want SC16b; then
echo "== SC16b: middle ellipsis cut at the tail =="
mutate engine/scenegraph/EllipsizeText.cpp "const size_t head = mode == 1 ? 0 : (keep + 1) / 2;" "const size_t head = mode == 1 ? 0 : keep;"
check SC16b ellipsizeMiddle; N=$((N + 1))
fi

if want SC17a; then
echo "== SC17a: painter ignores the fit scale =="
mutate engine/scenegraph/SceneGraph.cpp "    if (s < 1.0f) {" "    if (s < 0.0f) {"
check SC17a g2:adjustsFontSize; N=$((N + 1))
fi

if want SC17b; then
echo "== SC17b: fit search returns the minimum scale =="
mutate engine/text/FitScale.h "  return good;" "  return lo;"
check SC17b g2:adjustsFontSize; N=$((N + 1))
fi

if want SC18a; then
echo "== SC18a: generic families not mapped =="
mutate engine/text/FontFamily.cpp "    if (!kind.empty()) chosen = Generic(kind);" "    if (false) chosen = Generic(kind);"
check SC18a g2:fontMonospace; N=$((N + 1))
fi

if want SC18b; then
echo "== SC18b: stack entry not checked for existence =="
mutate engine/text/FontFamily.cpp "names.size() == 1 || Exists(names[i])" "true"
check SC18b g2:fontStack; N=$((N + 1))
fi

if want SC19a; then
echo "== SC19a: no font fallback =="
mutate engine/text/FontFallback.cpp "  if (!ascii && fc.ok && typography != nullptr) {" "  if (false && !ascii && fc.ok && typography != nullptr) {"
check SC19a risky:cjk; N=$((N + 1))
fi

if want SC19b; then
echo "== SC19b: Arabic block skipped by the fallback lookup =="
mutate engine/text/FontFallback.cpp "  std::string family;
  void* cs = fc.csCreate();" "  std::string family;
  if (cp >= 0x600 && cp <= 0x6FF) return byCp[cp] = family;
  void* cs = fc.csCreate();"
check SC19b risky:arabic; N=$((N + 1))
fi

if want SC20a; then
echo "== SC20a: TextInput fontWeight ignored =="
mutate engine/scenegraph/TextInputStyle.cpp "ApplyFontWeight(style, f.weight);" "ApplyFontWeight(style, 0);"
check SC20a g2:tiBold; N=$((N + 1))
fi

if want SC20b; then
echo "== SC20b: TextInput fontStyle ignored =="
mutate engine/scenegraph/TextInputStyle.cpp "ApplyFontStyle(style, f.italic);" "ApplyFontStyle(style, false);"
check SC20b g2:tiItalic; N=$((N + 1))
fi

if want SC20c; then
echo "== SC20c: right alignment shifted like centre =="
mutate engine/scenegraph/SceneGraph.cpp "  return a == 2 ? extra * 0.5f : extra;" "  return extra * 0.5f;"
check SC20c g2:tiAlignRight; N=$((N + 1))
fi

if want SC20d; then
echo "== SC20d: centre alignment never shifts the line =="
mutate engine/scenegraph/SceneGraph.cpp "(a != 2 && a != 3) || text.empty()) return 0.0f;" "a != 3 || text.empty()) return 0.0f;"
check SC20d g2:tiAlignCenter; N=$((N + 1))
fi

if want SC20e; then
echo "== SC20e: TextInput decoration line dropped =="
mutate engine/scenegraph/SceneGraph.cpp "rni::ApplyTextDecoration(style, node.tiFace.decoLine, node.tiFace.decoStyle," "rni::ApplyTextDecoration(style, 0, node.tiFace.decoStyle,"
check SC20e g2:tiDecoration; N=$((N + 1))
fi

if want SC20f; then
echo "== SC20f: TextInput textTransform not applied =="
mutate engine/scenegraph/SceneGraph.cpp "const std::string shownText = rni::applyTextTransform(text, node.tiFace.transform);" "const std::string shownText = text;"
check SC20f g2:tiTextTransform; N=$((N + 1))
fi

if want SC22a; then
echo "== SC22a: PlatformColor names never resolve =="
mutate engine/fabric/platform/impeller/PlatformColorTable.cpp "      if (name == entries[i].name) return &entries[i];" "      if (name == entries[i].name) return nullptr;"
check SC22a risky:platformColor; N=$((N + 1))
fi

if want SC22b; then
echo "== SC22b: systemBlue uses the dark value in light mode =="
mutate engine/fabric/platform/impeller/PlatformColorTable.cpp '{"systemBlue", {0, 122, 255, 1}' '{"systemBlue", {10, 132, 255, 1}'
check SC22b risky:platformColor; N=$((N + 1))
fi

if want SC24a; then
echo "== SC24a: Button fills the block with its colour =="
mutate package/src/metro-shims/shims/Button.impeller.js "      View,
      null," "      View,
      {style: {backgroundColor: color}},"
rebundle
check SC24a g2:button; N=$((N + 1))
fi

if want SC24b; then
echo "== SC24b: Button ignores color for the title =="
mutate package/src/metro-shims/shims/Button.impeller.js "    textStyles.push({color});" "    textStyles.push({color: '#007AFF'});"
rebundle
check SC24b g2:button; N=$((N + 1))
fi

if want SC25a; then
echo "== SC25a: hover feature flag defaults to false =="
mutate package/src/metro-shims/shims/ReactNativeFeatureFlags.impeller.js "    'shouldPressibilityUseW3CPointerEventsForHover',
    true," "    'shouldPressibilityUseW3CPointerEventsForHover',
    false,"
rebundle
check SC25a interact:hover; N=$((N + 1))
fi

if want SC27a; then
echo "== SC27a: scroll indicators never painted =="
mutate engine/scenegraph/SceneGraph.cpp "    rni::PaintScrollIndicators(builder, si);" ""
check SC27a g2:scrollIndicator; N=$((N + 1))
fi

if want SC27b; then
echo "== SC27b: indicator length ignores viewport/content =="
mutate engine/scenegraph/ScrollIndicators.cpp "  *len = std::min(track, std::max(kMinLength, track * viewport / content));" "  *len = track;"
check SC27b g2:scrollIndicator; N=$((N + 1))
fi

if want SC27c; then
echo "== SC27c: contentOffset.y ignored =="
mutate engine/scenegraph/SceneGraph.cpp "          node.scrollY = std::max(0.0f, coy);" "          node.scrollY = 0.0f;"
check SC27c scrollContentOffset; N=$((N + 1))
fi

if want SC27d; then
echo "== SC27d: contentOffset.x ignored =="
mutate engine/scenegraph/SceneGraph.cpp "          node.scrollX = std::max(0.0f, cox);" "          node.scrollX = 0.0f;"
check SC27d scrollHorizontal; N=$((N + 1))
fi

if want SC28a; then
echo "== SC28a: spokes do not fade =="
mutate engine/scenegraph/ActivityIndicator.cpp "static_cast<float>(k) / (kSpinnerSpokes - 1) * (1.0f - kMinAlpha);" "static_cast<float>(k) / (kSpinnerSpokes - 1) * 0.0f;"
check SC28a activityIndicator; N=$((N + 1))
fi

if want SC28b; then
echo "== SC28b: colour prop ignored =="
mutate engine/scenegraph/SceneGraph.cpp "      if (ap->color) colorToFloats(ap->color, node.spColor);" ""
check SC28b activityIndicator; N=$((N + 1))
fi

if want SC30a; then
echo "== SC30a: image never painted =="
mutate engine/scenegraph/ImagePaint.cpp "  if (texture == nullptr || texW <= 0" "  if (true || texture == nullptr || texW <= 0"
check SC30a g2:imageBackground; N=$((N + 1))
fi

if want SC30b; then
echo "== SC30b: tintColor ignored =="
mutate engine/scenegraph/SceneGraph.cpp "node.imgHasTint ? tint : nullptr" "nullptr"
check SC30b imageTint; N=$((N + 1))
fi

if want SC30c; then
echo "== SC30c: cover scales like contain =="
mutate engine/scenegraph/ImagePaint.cpp "    case 0: s = std::max(w / iw, h / ih); break;" "    case 0: s = std::min(w / iw, h / ih); break;"
check SC30c g2:imageCover; N=$((N + 1))
fi

if want SC30d; then
echo "== SC30d: image not clipped to a square box =="
mutate engine/scenegraph/SceneGraph.cpp "        ImpellerDisplayListBuilderClipRect(builder, &rect, kImpellerClipOperationIntersect);" ""
check SC30d g2:imageCover; N=$((N + 1))
fi

if want SC30e; then
echo "== SC30e: image not clipped to the rounded box =="
mutate engine/scenegraph/SceneGraph.cpp "      } else if (rounded) {
        ImpellerDisplayListBuilderClipRoundedRect(builder, &rect, &radii,
                                                  kImpellerClipOperationIntersect);" "      } else if (rounded) {"
check SC30e g2:imageRadius; N=$((N + 1))
fi

if want SC30f; then
echo "== SC30f: contain stretched =="
mutate engine/scenegraph/ImagePaint.cpp "if (resizeMode == 0 || resizeMode == 1 || resizeMode == 3) {" "if (resizeMode == 0 || resizeMode == 3) {"
check SC30f g2:imageContain; N=$((N + 1))
fi

if want SC30g; then
echo "== SC30g: center scales up like contain =="
mutate engine/scenegraph/ImagePaint.cpp "std::min(1.0f, std::min(w / iw, h / ih))" "std::min(w / iw, h / ih)"
check SC30g g2:imageCenter; N=$((N + 1))
fi

if want SC30h; then
echo "== SC30h: repeat stretched =="
mutate engine/scenegraph/ImagePaint.cpp "  if (resizeMode == 4) {" "  if (false) {"
check SC30h g2:imageRepeat; N=$((N + 1))
fi

if want SC32a; then
echo "== SC32a: custom SDK, letter spacing dropped (tools/mutation-verify-impeller-sdk-custom.sh) =="
ONLY=SC32a bash tools/mutation-verify-impeller-sdk-custom.sh || fail "SC32a (custom SDK gate)"
N=$((N + 1))
fi

if want SC32b; then
echo "== SC32b: custom SDK, word spacing stored as letter spacing (tools/mutation-verify-impeller-sdk-custom.sh) =="
ONLY=SC32b bash tools/mutation-verify-impeller-sdk-custom.sh || fail "SC32b (custom SDK gate)"
N=$((N + 1))
fi

if want SC32c; then
echo "== SC32c: custom SDK, font features dropped (tools/mutation-verify-impeller-sdk-custom.sh) =="
ONLY=SC32c bash tools/mutation-verify-impeller-sdk-custom.sh || fail "SC32c (custom SDK gate)"
N=$((N + 1))
fi

if want SC32d; then
echo "== SC32d: custom SDK, ClearFontFeatures no-op (tools/mutation-verify-impeller-sdk-custom.sh) =="
ONLY=SC32d bash tools/mutation-verify-impeller-sdk-custom.sh || fail "SC32d (custom SDK gate)"
N=$((N + 1))
fi

if want SC32e; then
echo "== SC32e: custom SDK, top placeholder alignment mapped to baseline (tools/mutation-verify-impeller-sdk-custom.sh) =="
ONLY=SC32e bash tools/mutation-verify-impeller-sdk-custom.sh || fail "SC32e (custom SDK gate)"
N=$((N + 1))
fi

if want SC32f; then
echo "== SC32f: custom SDK, placeholder rect x lost (tools/mutation-verify-impeller-sdk-custom.sh) =="
ONLY=SC32f bash tools/mutation-verify-impeller-sdk-custom.sh || fail "SC32f (custom SDK gate)"
N=$((N + 1))
fi

if want SC32g; then
echo "== SC32g: custom SDK, CMake keeps the stock SDK (tools/mutation-verify-impeller-sdk-custom.sh) =="
ONLY=SC32g bash tools/mutation-verify-impeller-sdk-custom.sh || fail "SC32g (custom SDK gate)"
N=$((N + 1))
fi

if want SC35a; then
echo "== SC35a: custom SDK, CMake keeps the stock SDK on darwin/win (tools/mutation-verify-impeller-sdk-custom.sh) =="
ONLY=SC35a bash tools/mutation-verify-impeller-sdk-custom.sh || fail "SC35a (custom SDK gate)"
N=$((N + 1))
fi

if want SC35b; then
echo "== SC35b: custom SDK, darwin driver copies the stock SDK (tools/mutation-verify-impeller-sdk-custom.sh) =="
ONLY=SC35b bash tools/mutation-verify-impeller-sdk-custom.sh || fail "SC35b (custom SDK gate)"
N=$((N + 1))
fi

if want SC33a; then
echo "== SC33a: Text letterSpacing not painted =="
mutate engine/scenegraph/SceneGraph.cpp "    ApplyLetterSpacing(style, run.letterSpacing);  // SC-33, measured too" ""
check SC33a nw:tracking; N=$((N + 1))
fi

if want SC33b; then
echo "== SC33b: TextInput letterSpacing ignored =="
mutate engine/scenegraph/TextInputStyle.cpp "  ApplyLetterSpacing(style, f.letterSpacing);  // SC-33" ""
check SC33b g2:tiLetterSpacing; N=$((N + 1))
fi

if want SC33c; then
echo "== SC33c: small-caps feature not set =="
mutate engine/text/TextStyle.h "  if (variant & (1 << 1)) ImpellerParagraphStyleSetFontFeature(style, \"smcp\", 1);" ""
check SC33c g2:smallCaps; N=$((N + 1))
fi

if want SC33d; then
echo "== SC33d: proportional-nums sets tnum =="
mutate engine/text/TextStyle.h "    ImpellerParagraphStyleSetFontFeature(style, \"pnum\", 1);" "    ImpellerParagraphStyleSetFontFeature(style, \"tnum\", 1);"
check SC33d tabularNums; N=$((N + 1))
fi

if want SC33e; then
echo "== SC33e: letterSpacing not measured =="
mutate engine/text/ImpellerTextLayoutManager.cpp "      ApplyLetterSpacing(style, (float)attrs.letterSpacing * scale);" ""
check SC33e nw:tracking; N=$((N + 1))
fi

if want SC34a; then
echo "== SC34a: paint skips the inline-View placeholder =="
mutate engine/scenegraph/SceneGraph.cpp "      AddAttachmentPlaceholder(pb, run.attachW, run.attachH);  // SC-34, measured too" ""
check SC34a risky:inlineView; N=$((N + 1))
fi

if want SC34b; then
echo "== SC34b: measured attachment frames not returned to Fabric =="
mutate engine/text/ImpellerTextLayoutManager.cpp "  ReadAttachmentFrames(paragraph, attachments);" ""
check SC34b risky:inlineView; N=$((N + 1))
fi

if want SC34c; then
echo "== SC34c: placeholder baseline offset 0 (box hangs below the baseline) =="
mutate engine/text/TextStyle.h "kImpellerPlaceholderAlignmentBaseline, h);" "kImpellerPlaceholderAlignmentBaseline, 0.0f);"
check SC34c risky:inlineView; N=$((N + 1))
fi

if [ -n "${ONLY:-}" ]; then
  echo "STYLE_COVERAGE_MUTATION_PARTIAL_PASS ($N mutant(s) of ONLY=$ONLY killed for their own tile)"
else
  echo "STYLE_COVERAGE_MUTATION_PASS ($N mutants killed for their own tile)"
fi
