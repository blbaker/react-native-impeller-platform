#include "scenegraph/SceneGraph.h"

#include "scenegraph/CaretBlink.h"
#include "scenegraph/CursorKinds.h"

#include <react/renderer/core/ConcreteState.h>
#include <react/renderer/components/textinput/BaseTextInputProps.h>
#include <react/renderer/components/iostextinput/TextInputProps.h>
#include <react/renderer/components/FBReactNativeSpec/Props.h>  // SwitchProps, ENG-15
#include <react/renderer/graphics/BackgroundImage.h>
#include <react/renderer/graphics/Color.h>
#include <react/renderer/graphics/LinearGradient.h>
#include "BackgroundLayers.h"
#include <react/renderer/graphics/Transform.h>

#if RNI_WITH_RNSVG
#include <react/renderer/components/rnsvg/Props.h>
#include "svg/SvgDash.h"
#include "svg/SvgPath.h"
#endif

#include "scenegraph/BorderDash.h"
#include "scenegraph/BorderCurve.h"
#include "scenegraph/BorderDashRounded.h"
#include "scenegraph/BorderRounded.h"
#include "scenegraph/Outline.h"
#include "scenegraph/ScrollIndicators.h"
#include "scenegraph/ColorMatrixFilter.h"
#include "scenegraph/BlendGroup.h"
#include "scenegraph/EllipsizeText.h"
#include "scenegraph/ContentFilters.h"
#include "text/FitScale.h"
#include "text/FontFamily.h"
#include "text/FontFallback.h"
#include "text/LineHeight.h"
#include "text/SecureText.h"
#include "text/TextStyle.h"
#include "text/TextTransform.h"

// ENG item 2 — supersample offscreen render. Direct GL entry points link on
// Linux (EGL GLESv2) and macOS (ANGLE dylibs), but NOT on Windows (resolved
// dynamically in WinGLSurface) or Android (Vulkan). Gate the whole offscreen
// path on the two platforms where gl* resolves at link time; elsewhere the
// helper is a stub that returns false and paintNode falls back to in-place.
#if !defined(_WIN32) && !defined(__ANDROID__)
#define RNI_SUPERSAMPLE_GL 1
#include <GLES3/gl3.h>
#else
#define RNI_SUPERSAMPLE_GL 0
#endif

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <functional>
#include <variant>

namespace {
// <TextInput> text inset from the field's left edge, in layout points. Used by
// paintNode (glyphs + caret) AND glyphBoundariesLocked (click-to-caret, item
// 3). One constant so the two cannot drift.
constexpr float kTextInputPad = 4.0f;

// ENG-16: y of a TextInput's first line. alignV is react::TextAlignmentVertical
// (0 Auto, 1 Top, 2 Bottom, 3 Center). Auto resolves to Top for a multiline
// field (iOS UITextView, and what Gluestack's Textarea expects) and Center for
// a single-line one (UITextField). Top/Bottom sit inside the content insets
// (padding + border), the box RN lays the text out in.
float TextInputLineTop(float y, float h, float blockH, float insetTop,
                       float insetBottom, bool multiline, int alignV) {
  int mode = alignV;
  if (mode == 0) mode = multiline ? 1 : 3;
  if (mode == 1) return y + insetTop;
  if (mode == 2) return y + h - insetBottom - blockH;
  return y + (h - blockH) * 0.5f;
}

// ENG-22: one setter for every paragraph style the painter builds (Paragraph,
// TextInput glyphs + selection + caret, click-to-caret boundaries), so the
// family measure used cannot be dropped from one paint path and not another.
void ApplyFontFamily(ImpellerParagraphStyle style, const std::string& family) {
  if (!family.empty()) {
    ImpellerParagraphStyleSetFontFamily(
        style, rni::ResolveFontFamily(family).c_str());
  }
}
}  // namespace

namespace rni {

namespace react = facebook::react;

namespace {

void colorToFloats(const react::SharedColor& color, float out[4]) {
  auto c = react::colorComponentsFromColor(color);
  out[0] = c.red;
  out[1] = c.green;
  out[2] = c.blue;
  out[3] = c.alpha;
}

ImpellerColor impellerColor(const float rgba[4], float opacity) {
  ImpellerColor c;
  c.red = rgba[0];
  c.green = rgba[1];
  c.blue = rgba[2];
  c.alpha = rgba[3] * opacity;
  c.color_space = kImpellerColorSpaceSRGB;
  return c;
}

#if RNI_WITH_RNSVG
// RNSVGPathProps::fill is folly::dynamic, not a real Props type — react-
// native-svg's extractFill.js hands the native side `{type, payload}`:
//   type 0 -> plain colour; `payload` is processColor()'s packed ARGB int32.
//   type 1 -> url(#id) gradient/pattern reference (`brushRef`); unsupported
//             here, matches skia-platform's tier-1 scope.
//   type 2 -> currentColor (inherited); unsupported at this tier.
//   fill=\"none\" (or a value processColor() rejects) -> payload absent.
// Returns false (no fill) rather than guessing, per D-honesty: an
// unsupported brush kind should paint NOTHING, not a wrong colour nothing
// could catch.
bool svgFillFromDynamic(const folly::dynamic& v, float out[4]) {
  if (!v.isObject()) return false;
  // ⛔ NEITHER FIELD IS RELIABLY AN INT. Measured, both arrive as DOUBLES:
  //   type_isInt=0  payload_isInt=0  payload_isDouble=1
  // These props cross into C++ as folly::dynamic decoded from JSON, and JSON
  // has one number type. folly picks int64 or double per value, so an
  // isInt()-only guard is a coin flip on the encoder's choice -- and it
  // rejected EVERY fill here, at the `type` check, before payload was even
  // reached. Read numerics by VALUE, never by storage class.
  auto* type = v.get_ptr("type");
  if (type == nullptr || !type->isNumber()) return false;
  if (type->asDouble() != 0.0) return false;  // gradient ref / currentColor: not tier 1
  auto* payload = v.get_ptr("payload");
  if (payload == nullptr) return false;  // "none"
  // ⛔ THE PAYLOAD DOES NOT FIT IN A SIGNED INT, AND folly SAYS SO BY TYPE.
  //
  // processColor() packs ARGB with the alpha in the TOP byte, so any opaque
  // colour is >= 0x80000000. Serialised through JSON that arrives as
  // 4294901760 (0xFFFF0000, opaque red) -- larger than INT32_MAX, so folly
  // stores it as a DOUBLE and `isInt()` is FALSE.
  //
  // The original guard was `if (!payload->isInt()) return false;`, which
  // therefore rejected every opaque colour and returned "no fill". Combined
  // with the paint guard's `&& node.svgHasFill`, the path was skipped
  // entirely: nothing drawn, no error, and painted_nodes STILL counted it
  // because that counter increments on node entry. Exactly the silent
  // failure docs/P9-SCOPE.md warns about -- and it was invisible until a gate
  // probed actual pixels.
  //
  // Semi-transparent fills (alpha < 0x80) DO land in int range, so a test
  // using only those would have passed while every solid colour failed.
  if (!payload->isNumber()) return false;  // unresolved brush
  const auto argb = static_cast<uint32_t>(static_cast<int64_t>(payload->asDouble()));
  out[3] = (float)((argb >> 24) & 0xFF) / 255.0f;
  out[0] = (float)((argb >> 16) & 0xFF) / 255.0f;
  out[1] = (float)((argb >> 8) & 0xFF) / 255.0f;
  out[2] = (float)(argb & 0xFF) / 255.0f;
  return true;
}
#endif

// Every RNSVG shape carries the SAME paint props (fill, fillOpacity, fillRule,
// stroke, strokeOpacity, strokeWidth, linecap/linejoin/miterlimit) -- they are
// declared per-class only because each generated Props is `final : public
// ViewProps` with no shared SVG base to inherit from.
//
// ⛔ A TEMPLATE, NOT FIVE COPIES. Duplicating this block per shape is how one
// component silently ends up reading strokeWidth as a number-only (invisible
// stroke on a length string) or inheriting rnsvg's miterlimit default of 0
// (every miter join collapses to a bevel) while its siblings stay correct.
// Written once, every shape gets every fix.
// Reads a brush that may be a plain colour OR a url(#id) reference.
// Returns true when `out` holds a usable colour; sets *ref when the brush is a
// reference instead (type 1), which the caller resolves against the gradient
// registry at paint time.
bool svgBrushFromDynamic(const folly::dynamic& v, float out[4], bool* isRef,
                         std::string* ref) {
  *isRef = false;
  ref->clear();
  if (!v.isObject()) return false;
  auto* type = v.get_ptr("type");
  if (type == nullptr || !type->isNumber()) return false;
  const int t = (int)type->asDouble();
  if (t == 1) {
    // url(#id) -- the gradient/pattern lives elsewhere in the tree.
    auto* br = v.get_ptr("brushRef");
    if (br != nullptr && br->isString()) {
      *isRef = true;
      *ref = br->asString();
    }
    return false;
  }
  if (t != 0) return false;  // currentColor / context-fill / context-stroke
  return svgFillFromDynamic(v, out);
}

// ENG-13: rnsvg sends strokeDasharray through extractLengthList: an array of
// numbers or length strings (odd lists already doubled in JS), or null for
// "none". A bare number or a "4 2" string is accepted too. Anything that is not
// a plain length (a percentage, a unit other than px, garbage) makes the whole
// list invalid, which SVG renders as a SOLID stroke, never a guessed pattern.
bool svgDashLength(const std::string& s, std::vector<float>* out) {
  size_t i = 0;
  while (i < s.size()) {
    while (i < s.size() && (std::isspace((unsigned char)s[i]) || s[i] == ',')) ++i;
    if (i >= s.size()) break;
    size_t used = 0;
    float f = 0.0f;
    try {
      f = std::stof(s.substr(i), &used);
    } catch (const std::exception&) {
      return false;
    }
    i += used;
    if (s.compare(i, 2, "px") == 0) i += 2;
    if (i < s.size() && !std::isspace((unsigned char)s[i]) && s[i] != ',') return false;
    out->push_back(f);
  }
  return true;
}

std::vector<float> svgDashFromDynamic(const folly::dynamic& v) {
  std::vector<float> raw;
  auto one = [&](const folly::dynamic& e) -> bool {
    if (e.isNumber()) {
      raw.push_back((float)e.asDouble());
      return true;
    }
    if (e.isString()) return svgDashLength(e.asString(), &raw);
    return false;
  };
  if (v.isArray()) {
    for (const auto& e : v) {
      if (!one(e)) return {};
    }
  } else if (!(v.isNumber() || v.isString()) || !one(v)) {
    return {};
  }
  return NormaliseSvgDashArray(raw);
}

template <typename P>
void readSvgPaintProps(SceneNode& node, const P* pp) {
  node.svgHasFill = svgBrushFromDynamic(pp->fill, node.svgFillColor,
                                        &node.svgFillIsRef, &node.svgFillRef);
  node.svgFillOpacity = (float)pp->fillOpacity;
  // fillRule: 0 = evenodd, 1 = nonzero.
  node.svgFillEvenOdd = (pp->fillRule == 0);

  node.svgHasStroke = svgBrushFromDynamic(pp->stroke, node.svgStrokeColor,
                                          &node.svgStrokeIsRef,
                                          &node.svgStrokeRef);
  node.svgStrokeOpacity = (float)pp->strokeOpacity;
  // strokeWidth is folly::dynamic: a number OR a length string ("2", "2px").
  node.svgStrokeWidth = 1.0f;
  if (pp->strokeWidth.isNumber()) {
    node.svgStrokeWidth = (float)pp->strokeWidth.asDouble();
  } else if (pp->strokeWidth.isString()) {
    try {
      node.svgStrokeWidth = std::stof(pp->strokeWidth.asString());
    } catch (const std::exception&) {
      node.svgStrokeWidth = 1.0f;
    }
  }
  node.svgStrokeLinecap = pp->strokeLinecap;
  node.svgStrokeLinejoin = pp->strokeLinejoin;
  // SVG's default miterlimit is 4; rnsvg's generated default is 0.
  node.svgStrokeMiterlimit =
      pp->strokeMiterlimit > 0.0 ? (float)pp->strokeMiterlimit : 4.0f;
  // ENG-13: dashes. Empty = solid.
  node.svgStrokeDash = svgDashFromDynamic(pp->strokeDasharray);
  node.svgStrokeDashOffset = (float)pp->strokeDashoffset;
}

// Shape geometry props are folly::dynamic because rnsvg accepts a number or a
// length string. Same by-value rule as everywhere else in this file.
float svgLength(const folly::dynamic& v, float fallback = 0.0f) {
  if (v.isNumber()) return (float)v.asDouble();
  if (v.isString()) {
    try {
      return std::stof(v.asString());
    } catch (const std::exception&) {
      return fallback;
    }
  }
  return fallback;
}

// Circle/Ellipse as four cubic arcs. kKappa is the standard circle-to-Bezier
// constant 4*(sqrt(2)-1)/3: the control-point offset that makes a cubic match
// a quarter arc to within ~0.02%.
constexpr float kKappa = 0.5522847498f;

// <Use> nesting limit. A symbol whose subtree contains a <Use> back to itself
// is invalid SVG but trivially expressible, and the naive recursion is an
// infinite loop on the render thread -- a HANG, which in a headless gate reads
// as a timeout with no output rather than as bad art. Six is deeper than any
// real icon set and shallow enough to be free.
constexpr int kMaxUseDepth = 6;

std::string ellipseToPathData(float cx, float cy, float rx, float ry) {
  if (rx <= 0.0f || ry <= 0.0f) return {};
  char buf[512];
  const float ox = rx * kKappa, oy = ry * kKappa;
  std::snprintf(buf, sizeof(buf),
                "M%g %g C%g %g %g %g %g %g C%g %g %g %g %g %g "
                "C%g %g %g %g %g %g C%g %g %g %g %g %g Z",
                cx - rx, cy,
                cx - rx, cy - oy, cx - ox, cy - ry, cx, cy - ry,
                cx + ox, cy - ry, cx + rx, cy - oy, cx + rx, cy,
                cx + rx, cy + oy, cx + ox, cy + ry, cx, cy + ry,
                cx - ox, cy + ry, cx - rx, cy + oy, cx - rx, cy);
  return buf;
}

}  // namespace

SceneGraph::SceneGraph(ImpellerTypographyContext typography)
    : typography_(typography) {}

SceneGraph::~SceneGraph() {
  // Release every cached offscreen texture. Ownership of each was transferred
  // to Impeller when it was adopted from the GL handle, so Impeller frees the
  // underlying GL texture on the last Release — we must not glDeleteTextures it.
  for (auto& [key, entry] : svgCache_) {
    if (entry.texture) ImpellerTextureRelease(entry.texture);
  }
  // <world> ENG-09. Same ownership rule as svgCache_ above -- release the
  // adopted texture, never glDeleteTextures the GL handle it wraps.
  for (auto& [tag, entry] : worldTextureCache_) {
    if (entry.texture) ImpellerTextureRelease(entry.texture);
  }
  // ENG-10 sprite atlas -- same ownership rule.
  for (auto& [id, entry] : spriteTextureCache_) {
    if (entry.texture) ImpellerTextureRelease(entry.texture);
  }
  // ENG item 2b — the double-buffered whole-tree offscreen, if a root
  // supersample ran on the final frame and nothing consumed the successor.
  if (treeTexture_) ImpellerTextureRelease(treeTexture_);
}

void SceneGraph::updateFromShadowView(SceneNode& node,
                                      const react::ShadowView& view) {
  node.tag = view.tag;
  // ⛔ RETAIN THE EVENT EMITTER OR TOUCH DISPATCH HAS NO TARGET.
  // This is the ONLY point where the emitter is reachable: it rides on the
  // ShadowView through the mounting transaction and is then dropped. Fabric
  // owns the ShadowNode on the JS thread and the host must never reach back
  // into the shadow tree to find it, so the emitter is captured here (it is a
  // shared_ptr, so holding it is safe across threads) and used later by
  // FabricHost::dispatchTouch. Without this line a hit test resolves a correct
  // tag and then has nothing to deliver the event to.
  node.eventEmitter = view.eventEmitter;
  node.componentName = view.componentName ? view.componentName : "";
  node.layoutMetrics = view.layoutMetrics;

  if (const auto* props = dynamic_cast<const react::ViewProps*>(view.props.get())) {
    node.opacity = (float)props->opacity;

    if (props->backgroundColor) {
      node.hasBackgroundColor = true;
      colorToFloats(props->backgroundColor, node.bg);
    } else {
      node.hasBackgroundColor = false;
    }
    // item 11: parsed by the tvos HostPlatformViewProps (see
    // cmake/ReactCommonFabric.cmake for why tvos, not cxx).
    node.focusable = props->focusable;

    // BORDERS. RN carries widths/colours/radii as a CASCADE (all / horizontal /
    // vertical / per-edge / logical start-end), never as plain numbers.
    // `resolveBorderMetrics` does the whole cascade including logical->physical
    // for the layout direction, so we ask for it once rather than resolving
    // three cascades by hand and getting the RTL rules subtly wrong.
    //
    // P2 resolved the cascade and then took `.left` for all four edges. That is
    // invisible on a uniform border and wrong for every single-edge one.
    const auto metrics = props->resolveBorderMetrics(view.layoutMetrics);
    const react::Float widths[4] = {metrics.borderWidths.top,
                                    metrics.borderWidths.right,
                                    metrics.borderWidths.bottom,
                                    metrics.borderWidths.left};
    const react::SharedColor colors[4] = {metrics.borderColors.top,
                                          metrics.borderColors.right,
                                          metrics.borderColors.bottom,
                                          metrics.borderColors.left};
    // Items 10 + 25. RN iOS takes the TOP edge's style for the whole border
    // (RCTViewComponentView: borderMetrics.borderStyles.top) -- same here.
    node.borderStyle = (int)metrics.borderStyles.top;
    node.outlineWidth = (float)props->outlineWidth;
    node.outlineOffset = (float)props->outlineOffset;
    node.outlineStyle = (int)props->outlineStyle;
    if (props->outlineColor) colorToFloats(props->outlineColor, node.outlineColor);
    else node.outlineColor[0] = node.outlineColor[1] = node.outlineColor[2] = 0.0f,
         node.outlineColor[3] = 1.0f;
    for (int i = 0; i < 4; ++i) {
      node.borderWidths[i] = (float)widths[i];
      // SC-03: a width with no resolved colour paints opaque black (RN default).
      node.hasBorderColors[i] = (bool)colors[i] || widths[i] > 0;
      if (colors[i]) colorToFloats(colors[i], node.borderColors[i]);
      else node.borderColors[i][0] = node.borderColors[i][1] = node.borderColors[i][2] = 0.0f,
           node.borderColors[i][3] = 1.0f;
    }

    // Radii in IMPELLER's field order (TL, BL, TR, BR), which is NOT the order
    // RN stores them in and NOT clockwise. Getting this wrong rounds the wrong
    // corners while still producing a rounded-looking box.
    node.borderRadii[0] = (float)metrics.borderRadii.topLeft.horizontal;
    node.borderRadii[1] = (float)metrics.borderRadii.bottomLeft.horizontal;
    node.borderRadii[2] = (float)metrics.borderRadii.topRight.horizontal;
    node.borderRadii[3] = (float)metrics.borderRadii.bottomRight.horizontal;
    node.borderRadiiV[0] = (float)metrics.borderRadii.topLeft.vertical;
    node.borderRadiiV[1] = (float)metrics.borderRadii.bottomLeft.vertical;
    node.borderRadiiV[2] = (float)metrics.borderRadii.topRight.vertical;
    node.borderRadiiV[3] = (float)metrics.borderRadii.bottomRight.vertical;
    node.borderContinuous = metrics.borderCurves.topLeft == react::BorderCurve::Continuous ||
                            metrics.borderCurves.topRight == react::BorderCurve::Continuous ||
                            metrics.borderCurves.bottomLeft == react::BorderCurve::Continuous ||
                            metrics.borderCurves.bottomRight == react::BorderCurve::Continuous;

    node.overflowHidden = props->getClipsContentToBounds();

    // SHADOWS. Style audit items 1-4.
    //
    // iOS model: CALayer shadow = shadowColor at shadowOpacity, offset by
    // shadowOffset, blurred by shadowRadius. Painted only when opacity > 0 and
    // the colour is visible, exactly the RCTViewComponentView test
    // (layerHasShadow). RN's BaseViewProps defaults shadowOffset to (0,-3) and
    // shadowRadius to 3, so a bare shadowOpacity still casts a shadow upward,
    // as on iOS.
    //
    // CALayer shadowRadius r reads like a gaussian of sigma ~ r/2; RN's own
    // boxShadow path sets CALayer radius = blurRadius/2, i.e. CSS blur B
    // corresponds to CALayer radius B/2, and CSS blur B is sigma B/2. So the
    // CALayer radius is used as sigma directly for iOS shadows, and blur/2
    // for boxShadow, which keeps the two models consistent with each other.
    node.shadows.clear();
    node.hasLayerShadow = false;
    {
      float sc[4] = {0, 0, 0, 1};
      const bool hasColor = (bool)props->shadowColor;
      if (hasColor) colorToFloats(props->shadowColor, sc);
      const float op = std::clamp((float)props->shadowOpacity, 0.0f, 1.0f);
      if (op > 0.0f && sc[3] > 0.0f) {
        ShadowSpec s;
        s.offsetX = (float)props->shadowOffset.width;
        s.offsetY = (float)props->shadowOffset.height;
        s.sigma = std::max(0.0f, (float)props->shadowRadius);
        for (int k = 0; k < 4; ++k) s.color[k] = sc[k];
        s.color[3] *= op;
        // A CALayer shadow is cast by the layer's alpha, so it shows through
        // a translucent background (no clip-out, unlike CSS boxShadow). With
        // an opaque background the box paints over the umbra either way.
        s.clipOutsideBox = false;
        node.layerShadow = s;
        node.hasLayerShadow = true;
      }
    }
    for (const auto& bs : props->boxShadow) {
      ShadowSpec s;
      s.offsetX = (float)bs.offsetX;
      s.offsetY = (float)bs.offsetY;
      s.sigma = std::max(0.0f, (float)bs.blurRadius) * 0.5f;
      s.spread = (float)bs.spreadDistance;
      s.inset = bs.inset;
      s.clipOutsideBox = true;
      if (bs.color) {
        colorToFloats(bs.color, s.color);
      } else {
        s.color[0] = s.color[1] = s.color[2] = 0.0f;  // CSS: currentColor;
        s.color[3] = 1.0f;                              // black in RN
      }
      node.shadows.push_back(s);
    }
    // ViewProps IS HostPlatformViewProps; ours (engine/fabric/platform/
    // impeller) parses elevation, which RN's tvos/cxx variants drop.
    node.elevation = std::max(0.0f, (float)props->elevation);
    // Android tints the material shadow with outlineSpotShadowColor; RN does
    // not expose it on Fabric desktop, so elevation shadows are black, as on
    // an Android device with default theming.
    node.elevationColor[0] = node.elevationColor[1] = node.elevationColor[2] = 0.0f;
    node.elevationColor[3] = 1.0f;
    // ENG-09 hover/cursor. RN's Cursor enum -> the nearest GLFW standard
    // shape (CursorKinds.h); a view with no cursor prop stays arrow.
    node.cursorKind = rni::CursorKindFromRN(props->cursor);

    // <ScrollView>. ENG-02.
    //
    // ⛔ IDENTIFIED BY COMPONENT NAME, AND THE NAME IS ONLY CORRECT BECAUSE THE
    // DESCRIPTOR IS REGISTERED. An unregistered ScrollView arrives here with
    // componentName "ScrollView" too -- the name rides on the ShadowView -- but
    // with plain ViewProps and, crucially, a base ViewEventEmitter, so the
    // dynamic_cast in FabricHost::dispatchScroll fails and onScroll can never
    // fire. Marking isScrollView is therefore necessary and NOT sufficient; the
    // registration in FabricHost.cpp is the other half.
    //
    // ⚠️ scrollY IS NOT RESET HERE. This function runs on every Update
    // mutation, and clearing the offset would scroll the list back to the top
    // whenever any prop on it changed.
    node.isScrollView = (node.componentName == "ScrollView");
    if (node.isScrollView) {
      // Axis fallback only. `horizontal` arrives false for `<ScrollView
      // horizontal>` off Android (RN never swaps in the dedicated
      // AndroidHorizontalScrollView), so scrollBy derives the real axis from
      // content overflow and consults this only when neither/both axes overflow.
      if (const auto* sp =
              dynamic_cast<const react::ScrollViewProps*>(view.props.get())) {
        node.scrollHorizontal = sp->horizontal;
        node.showsVerticalScrollIndicator = sp->showsVerticalScrollIndicator;
        node.showsHorizontalScrollIndicator = sp->showsHorizontalScrollIndicator;
        node.scrollIndicatorStyle = static_cast<int>(sp->indicatorStyle);
        // contentOffset is applied on mount and whenever the prop value changes;
        // an unrelated re-render must not snap a scrolled list back.
        const float cox = (float)sp->contentOffset.x, coy = (float)sp->contentOffset.y;
        if (!node.contentOffsetSeen || cox != node.contentOffsetPropX ||
            coy != node.contentOffsetPropY) {
          node.scrollX = std::max(0.0f, cox);
          node.scrollY = std::max(0.0f, coy);
          node.contentOffsetSeen = true;
          node.contentOffsetPropX = cox;
          node.contentOffsetPropY = coy;
        }
      }
      // A ScrollView clips by definition. RN's ScrollViewProps does not set
      // overflow:hidden by default the way a native scroll view implies it, so
      // relying on getClipsContentToBounds alone leaves the off-screen rows
      // painting over everything below the viewport -- content that scrolls
      // correctly and is drawn outside its own frame.
      node.overflowHidden = true;
    }

    // TRANSFORM. resolveTransform() applies transform-origin and turns the
    // operation list into a matrix; reading props->transform.matrix directly
    // skips the origin translation, so a rotation would pivot about the node's
    // top-left instead of its centre — a wrong-but-plausible frame.
    // parity item 9: pointerEvents, read with the other view props.
    switch (props->pointerEvents) {
      case react::PointerEventsMode::None: node.pointerEvents = 1; break;
      case react::PointerEventsMode::BoxNone: node.pointerEvents = 2; break;
      case react::PointerEventsMode::BoxOnly: node.pointerEvents = 3; break;
      default: node.pointerEvents = 0; break;
    }
    node.hasFilterMatrix = rni::BuildFilterMatrix(props->filter, node.filterMatrix);
    node.mixBlend = props->mixBlendMode;
    node.isolate = props->isolation == react::Isolation::Isolate;
    rni::ParseContentFilters(props->filter, node.blurSigma, node.dropShadows);
    node.hasTransform = false;
    node.backfaceHidden = false;
    if (!props->transform.operations.empty()) {
      const auto resolved = props->resolveTransform(view.layoutMetrics);
      node.transform = resolved.matrix;
      node.hasTransform = resolved != react::Transform::Identity();
      node.backfaceHidden = false;
      if (props->backfaceVisibility == react::BackfaceVisibility::Hidden) {
        // Orientation of the z=0 plane after the transform: determinant of the
        // x, y, w rows over columns 0, 1, 3. Negative means the back faces us.
        const auto& m = node.transform;
        const double det = m[0] * (m[5] * m[15] - m[13] * m[7]) -
                           m[4] * (m[1] * m[15] - m[13] * m[3]) +
                           m[12] * (m[1] * m[7] - m[5] * m[3]);
        node.backfaceHidden = det < 0;
      }
    }

    // experimental_backgroundImage: linear and radial layers (BackgroundLayers.cpp).
    node.bgLayers = BuildBackgroundLayers(
        props->backgroundImage, props->backgroundSize, props->backgroundPosition,
        props->backgroundRepeat, (float)view.layoutMetrics.frame.size.width,
        (float)view.layoutMetrics.frame.size.height);
  }

  // <Text>: the measured AttributedString rides on ParagraphState, which is
  // exactly what Fabric measured with. Painting from the props instead would
  // let measure and paint disagree.
  if (node.componentName == "Paragraph") {
    node.isParagraph = true;
    node.text.clear();
    node.fontFamily.clear();
    node.lineHeight = 0.0f;
    node.fontWeight = 0;
    node.textAlign = 0;
    node.writingDirection = 0;
    node.textVAlign = 0;
    node.decoLine = 0;
    node.decoStyle = 0;
    node.hasDecoColor = false;
    node.maxLines = 0;
    node.adjustsFit = false;
    node.minFontScale = 0.0f;
    node.ellipsizeMode = 0;
    node.textTransform = 0;
    if (const auto* pp =
            dynamic_cast<const react::ParagraphProps*>(view.props.get())) {
      node.maxLines = pp->paragraphAttributes.maximumNumberOfLines;
      node.adjustsFit = pp->paragraphAttributes.adjustsFontSizeToFit;
      node.minFontScale = (float)pp->paragraphAttributes.minimumFontScale;
      // ellipsizeMode is only consulted when the paragraph is line-clamped; an
      // unclamped Text never truncates, so the mode is irrelevant there.
      node.ellipsizeMode = (int)pp->paragraphAttributes.ellipsizeMode;
      node.selectable = pp->isSelectable;  // P1 item 15
      if (pp->paragraphAttributes.textAlignVertical.has_value()) {
        node.textVAlign = (int)*pp->paragraphAttributes.textAlignVertical;
      }
    }
    // textTransform rides on the per-fragment TextAttributes, not on
    // ParagraphProps. Read it from the FIRST non-empty fragment: RN resolves a
    // single Text's transform onto every fragment, so the first is
    // representative, and per-fragment mixed transforms are a later phase.
    int fragTransform = 0;
    if (view.state) {
      // The state type is ParagraphShadowNode::ConcreteStateData's holder;
      // spelling it via the shadow node avoids guessing the template args.
      const auto& stateData =
          static_cast<const facebook::react::ConcreteState<
              facebook::react::ParagraphState>&>(*view.state)
              .getData();
      bool tookTransform = false;
      node.runs.clear();
      for (const auto& fragment : stateData.attributedString.getFragments()) {
        // P1 item 14: an inline-view attachment is a U+FFFC placeholder that
        // measure skips (ImpellerTextLayoutManager), so paint skips it too
        // instead of drawing a replacement glyph in a box sized without it.
        if (!fragment.isAttachment()) {
          const auto& fa = fragment.textAttributes;
          TextRun run;
          run.text = applyTextTransform(
              fragment.string,
              fa.textTransform.has_value() ? (int)fa.textTransform.value() : 0);
          if (fa.fontSize > 0) run.fontSize = (float)fa.fontSize;
          run.fontFamily = fa.fontFamily;
          if (fa.lineHeight > 0) run.lineHeight = (float)fa.lineHeight;
          if (fa.fontWeight.has_value()) run.fontWeight = (int)*fa.fontWeight;
          run.italic = fa.fontStyle.has_value() && *fa.fontStyle != react::FontStyle::Normal;
          if (std::isfinite(fa.opacity)) run.opacity = std::clamp((float)fa.opacity, 0.0f, 1.0f);
          const float sOffX = fa.textShadowOffset ? (float)fa.textShadowOffset->width : 0.0f;
          const float sOffY = fa.textShadowOffset ? (float)fa.textShadowOffset->height : 0.0f;
          const float sRad = std::isfinite(fa.textShadowRadius) ? std::max(0.0f, (float)fa.textShadowRadius) : 0.0f;
          if (sOffX != 0.0f || sOffY != 0.0f || sRad > 0.0f) {
            run.hasShadow = true;
            run.shadowOffX = sOffX;
            run.shadowOffY = sOffY;
            run.shadowSigma = sRad * 0.5f;  // as boxShadow: CSS blur B is sigma B/2
            if (fa.textShadowColor) colorToFloats(fa.textShadowColor, run.shadowColor);
          }
          if (fa.textDecorationLineType.has_value()) {
            run.decoLine = (int)*fa.textDecorationLineType;
          }
          if (fa.textDecorationStyle.has_value()) {
            run.decoStyle = (int)*fa.textDecorationStyle;
          }
          if (fa.textDecorationColor) {
            colorToFloats(fa.textDecorationColor, run.decoColor);
            run.hasDecoColor = true;
          }
          if (fa.foregroundColor) colorToFloats(fa.foregroundColor, run.color);
          if (fa.backgroundColor) {
            colorToFloats(fa.backgroundColor, run.background);
            run.hasBackground = run.background[3] > 0.0f;
          }
          node.runs.push_back(std::move(run));
        }
        node.text += fragment.string;
        if (fragment.textAttributes.fontSize > 0) {
          node.fontSize = (float)fragment.textAttributes.fontSize;
        }
        // Same last-fragment-wins rule as fontSize: RN resolves a Text's
        // family onto every fragment, so a uniform label is exact. Mixed
        // families inside one paragraph are per-fragment spans (parity 16).
        if (!fragment.textAttributes.fontFamily.empty()) {
          node.fontFamily = fragment.textAttributes.fontFamily;
        }
        // ENG-23: same last-fragment-wins rule; NaN (unset) is skipped.
        if (fragment.textAttributes.lineHeight > 0) {
          node.lineHeight = (float)fragment.textAttributes.lineHeight;
        }
        // Style audit items 5, 7, 9: same last-fragment-wins rule.
        const auto& ta = fragment.textAttributes;
        if (ta.fontWeight.has_value()) node.fontWeight = (int)*ta.fontWeight;
        if (ta.alignment.has_value()) node.textAlign = (int)*ta.alignment;
        if (ta.baseWritingDirection.has_value()) {
          node.writingDirection = (int)*ta.baseWritingDirection;
        }
        if (ta.textDecorationLineType.has_value()) {
          node.decoLine = (int)*ta.textDecorationLineType;
        }
        if (ta.textDecorationStyle.has_value()) {
          node.decoStyle = (int)*ta.textDecorationStyle;
        }
        if (ta.textDecorationColor) {
          colorToFloats(ta.textDecorationColor, node.decoColor);
          node.hasDecoColor = true;
        }
        if (fragment.textAttributes.foregroundColor) {
          colorToFloats(fragment.textAttributes.foregroundColor, node.textColor);
        }
        if (!tookTransform && fragment.textAttributes.textTransform.has_value()) {
          fragTransform = (int)fragment.textAttributes.textTransform.value();
          tookTransform = true;
        }
      }
    }
    node.textTransform = fragTransform;
    // Applied HERE, once, so node.text is the exact string the painter draws and
    // (were measure to read it) the exact string measured — never the raw case
    // in one and the transformed case in the other.
    if (fragTransform == 1 || fragTransform == 2 || fragTransform == 3) {
      node.text = applyTextTransform(node.text, fragTransform);
    }
  }

  // <Switch>. ENG-15. Switch.js's iOS arm sends value / disabled / onTintColor
  // (trackColor.true) / tintColor (trackColor.false) / thumbTintColor
  // (thumbColor). An unset colour keeps the iOS default in SceneNode.
  if (node.componentName == "Switch") {
    node.isSwitch = true;
    if (const auto* sp = dynamic_cast<const react::SwitchProps*>(view.props.get())) {
      if (!node.swHasProp || sp->value != node.swPropValue) node.swValue = sp->value;
      node.swPropValue = sp->value;
      node.swHasProp = true;
      node.swDisabled = sp->disabled;
      if (sp->onTintColor) colorToFloats(sp->onTintColor, node.swOnColor);
      if (sp->tintColor) colorToFloats(sp->tintColor, node.swOffColor);
      if (sp->thumbTintColor) colorToFloats(sp->thumbTintColor, node.swThumbColor);
    }
  }

  // <TextInput>. ENG-01b. The component name RN gives the iOS single-line input
  // is "TextInput" (iostextinput's TextInputComponentName). Its controlled value
  // rides on BaseTextInputProps::text; placeholder and its colour are siblings.
  // Font size/colour come from the effective TextAttributes, the SAME resolver
  // <Text> uses, so an input and a label at one fontSize paint identically.
  if (node.componentName == "TextInput") {
    node.isTextInput = true;
    node.tiValue.clear();
    node.tiPlaceholder.clear();
    if (const auto* tp =
            dynamic_cast<const react::BaseTextInputProps*>(view.props.get())) {
      node.tiValue = tp->text;
      node.tiPlaceholder = tp->placeholder;
      node.tiMultiline = tp->multiline;  // ENG-16
      node.tiSubmitBehavior = (int)tp->getNonDefaultSubmitBehavior();  // ENG-24
      // Style audit item 11: secureTextEntry lives on the iOS TextInputProps'
      // traits, not on BaseTextInputProps.
      node.tiSecure = false;
      if (const auto* itp = dynamic_cast<const react::TextInputProps*>(tp)) {
        node.tiSecure = itp->traits.secureTextEntry;
      }
      node.tiAlignVertical =
          tp->paragraphAttributes.textAlignVertical.has_value()
              ? (int)*tp->paragraphAttributes.textAlignVertical
              : 0;
      node.tiEditable = tp->editable;  // item 11
      const auto attrs = tp->getEffectiveTextAttributes(1.0f);
      if (attrs.fontSize > 0) node.fontSize = (float)attrs.fontSize;
      node.fontFamily = attrs.fontFamily;  // ENG-22
      // ENG-23 (TextInput): lineHeight in points; NaN/0 = unset. The measure
      // side (ImpellerTextLayoutManager) already applies it, so paint must too.
      node.lineHeight = (attrs.lineHeight > 0 && std::isfinite(attrs.lineHeight))
                            ? (float)attrs.lineHeight
                            : 0.0f;
      if (attrs.foregroundColor) {
        colorToFloats(attrs.foregroundColor, node.textColor);
      }
      if (tp->placeholderTextColor) {
        colorToFloats(tp->placeholderTextColor, node.tiPlaceholderColor);
      }
      // SC-20: the Text attributes a field honours, plus the caret props.
      rni::TextInputFace& face = node.tiFace;
      face = rni::TextInputFace{};
      face.align = attrs.alignment.has_value() ? (int)*attrs.alignment : 0;
      face.weight = attrs.fontWeight.has_value() ? (int)*attrs.fontWeight : 0;
      face.italic = attrs.fontStyle.has_value() && *attrs.fontStyle != react::FontStyle::Normal;
      face.decoLine = attrs.textDecorationLineType.has_value() ? (int)*attrs.textDecorationLineType : 0;
      face.decoStyle = attrs.textDecorationStyle.has_value() ? (int)*attrs.textDecorationStyle : 0;
      face.transform = attrs.textTransform.has_value() ? (int)*attrs.textTransform : 0;
      if (attrs.textDecorationColor) {
        colorToFloats(attrs.textDecorationColor, face.decoColor);
        face.hasDecoColor = true;
      }
      if (tp->cursorColor) {
        colorToFloats(tp->cursorColor, face.cursorColor);
        face.hasCursorColor = true;
      }
      if (const auto* itp2 = dynamic_cast<const react::TextInputProps*>(tp)) {
        face.caretHidden = itp2->traits.caretHidden;
      }
      // item 4a: the field's own selectionColor prop, when the fork exposes
      // one -- BaseTextInputProps carries it unconditionally (RN core, not
      // an iOS/Android-only extension). Falls through to the struct's own
      // default (rgba(51,144,255,0.35)) when the prop is unset.
      if (tp->selectionColor) {
        colorToFloats(tp->selectionColor, node.tiSelectionColor);
      }
    }
  }

#if RNI_WITH_RNSVG
  // RNSVGPath: parse `d` into geometry (re-parsing only on change — the SVG
  // path parser is the expensive step and props re-snapshot on every commit)
  // and capture fill/fillRule. Group's `matrix` field is a documented known
  // gap (see docs/STATE.md P9-B2) — not consumed here.
  node.isSvgPath = false;
  // ⛔ THE MATRIX IS READ FOR EVERY RNSVG COMPONENT, NOT JUST <Path>.
  //
  // `matrix` appears on Group, Path and every shape -- but each generated
  // Props class is `final : public ViewProps` with NO shared RNSVG base, so
  // there is nothing to dynamic_cast to once. Reading it only on Path is the
  // exact half-fix that leaves <G transform> silently dropped: the bug that
  // shipped on skia-platform and cost a long hunt there (content 4.87x
  // oversized, no error anywhere).
  //
  // Six floats, column-major [a, b, c, d, tx, ty] from react-native-svg's
  // extractTransform(). A different length is a prop shape we do not
  // understand, so ignore it rather than read off the end.
  node.hasSvgMatrix = false;
  {
    const std::vector<react::Float>* mtx = nullptr;
    if (const auto* p = dynamic_cast<const react::RNSVGPathProps*>(view.props.get())) {
      mtx = &p->matrix;
    } else if (const auto* g = dynamic_cast<const react::RNSVGGroupProps*>(view.props.get())) {
      mtx = &g->matrix;
    }
    if (mtx != nullptr && mtx->size() == 6) {
      static constexpr float kIdent[6] = {1, 0, 0, 1, 0, 0};
      bool identity = true;
      for (int i = 0; i < 6; ++i) {
        node.svgMatrix[i] = (float)(*mtx)[i];
        if (node.svgMatrix[i] != kIdent[i]) identity = false;
      }
      // An identity matrix costs a save/restore pair per node for nothing.
      node.hasSvgMatrix = !identity;
    }
  }
  // ⛔ EVERY SHAPE BECOMES A `d` STRING AND REUSES ONE PAINT PATH.
  //
  // Circle/Rect/Ellipse/Line differ from Path ONLY in geometry -- their paint
  // props are identical (see readSvgPaintProps). Converting each to path data
  // means fill-rule, per-path fill-opacity, stroke colour/width/caps/joins and
  // the <G transform> matrix are all inherited automatically, and there is one
  // painter to fix rather than five to keep in sync.
  //
  // node.isSvgPath therefore means "has path data to fill/stroke", not
  // "is literally an <Path> element".
  if (node.componentName == "RNSVGPath") {
    if (const auto* pp =
            dynamic_cast<const react::RNSVGPathProps*>(view.props.get())) {
      node.isSvgPath = true;
      node.svgD = pp->d;
      readSvgPaintProps(node, pp);
    }
  } else if (node.componentName == "RNSVGRect") {
    if (const auto* pp =
            dynamic_cast<const react::RNSVGRectProps*>(view.props.get())) {
      const float x = svgLength(pp->x), y = svgLength(pp->y);
      const float w = svgLength(pp->width), h = svgLength(pp->height);
      // SVG: if only one of rx/ry is given the other takes its value.
      float rx = svgLength(pp->rx, -1.0f), ry = svgLength(pp->ry, -1.0f);
      if (rx < 0.0f && ry >= 0.0f) rx = ry;
      if (ry < 0.0f && rx >= 0.0f) ry = rx;
      if (rx < 0.0f) rx = 0.0f;
      if (ry < 0.0f) ry = 0.0f;
      rx = std::min(rx, w * 0.5f);
      ry = std::min(ry, h * 0.5f);
      if (w > 0.0f && h > 0.0f) {
        char buf[512];
        if (rx > 0.0f && ry > 0.0f) {
          const float ox = rx * kKappa, oy = ry * kKappa;
          std::snprintf(buf, sizeof(buf),
                        "M%g %g L%g %g C%g %g %g %g %g %g L%g %g "
                        "C%g %g %g %g %g %g L%g %g C%g %g %g %g %g %g "
                        "L%g %g C%g %g %g %g %g %g Z",
                        x + rx, y, x + w - rx, y,
                        x + w - rx + ox, y, x + w, y + ry - oy, x + w, y + ry,
                        x + w, y + h - ry,
                        x + w, y + h - ry + oy, x + w - rx + ox, y + h, x + w - rx, y + h,
                        x + rx, y + h,
                        x + rx - ox, y + h, x, y + h - ry + oy, x, y + h - ry,
                        x, y + ry,
                        x, y + ry - oy, x + rx - ox, y, x + rx, y);
        } else {
          std::snprintf(buf, sizeof(buf), "M%g %g L%g %g L%g %g L%g %g Z",
                        x, y, x + w, y, x + w, y + h, x, y + h);
        }
        node.isSvgPath = true;
        node.svgD = buf;
        readSvgPaintProps(node, pp);
      }
    }
  } else if (node.componentName == "RNSVGCircle") {
    if (const auto* pp =
            dynamic_cast<const react::RNSVGCircleProps*>(view.props.get())) {
      const float r = svgLength(pp->r);
      node.svgD = ellipseToPathData(svgLength(pp->cx), svgLength(pp->cy), r, r);
      if (!node.svgD.empty()) {
        node.isSvgPath = true;
        readSvgPaintProps(node, pp);
      }
    }
  } else if (node.componentName == "RNSVGEllipse") {
    if (const auto* pp =
            dynamic_cast<const react::RNSVGEllipseProps*>(view.props.get())) {
      node.svgD = ellipseToPathData(svgLength(pp->cx), svgLength(pp->cy),
                                    svgLength(pp->rx), svgLength(pp->ry));
      if (!node.svgD.empty()) {
        node.isSvgPath = true;
        readSvgPaintProps(node, pp);
      }
    }
  } else if (node.componentName == "RNSVGLine") {
    if (const auto* pp =
            dynamic_cast<const react::RNSVGLineProps*>(view.props.get())) {
      char buf[128];
      std::snprintf(buf, sizeof(buf), "M%g %g L%g %g",
                    svgLength(pp->x1), svgLength(pp->y1),
                    svgLength(pp->x2), svgLength(pp->y2));
      node.isSvgPath = true;
      node.svgD = buf;
      readSvgPaintProps(node, pp);
      // ⚠️ A <Line> is an OPEN path: it has no interior, so a fill can never
      // show. rnsvg still defaults `fill` to black (SVG spec), which would
      // make the fill pass draw nothing while looking like it should. Drop it
      // so the stroke pass is unambiguously what paints.
      node.svgHasFill = false;
    }
  } else if (node.componentName == "RNSVGSvgView") {
    // ⛔ THE ROOT <Svg> IS A VIEWPORT, NOT A CONTAINER. ENG-05a.
    //
    // Before this branch existed the chain fell straight through to the else,
    // so a root <Svg viewBox="0 0 24 24"> at width 16 height 16 declared a
    // 16x16 Yoga frame and then painted 24 user units of path data into it at
    // 1:1. Every design-system Icon is a 24-unit viewBox drawn at 16 in buttons
    // and 20 in the rail, so every glyph overflowed its centred box downward
    // and sat low. The props were never missing -- RNSVGSvgViewProps has
    // carried minX/minY/vbWidth/vbHeight all along (engine/svg/generated/react/
    // renderer/components/rnsvg/Props.h) -- there was simply no consumer.
    if (const auto* pp =
            dynamic_cast<const react::RNSVGSvgViewProps*>(view.props.get())) {
      node.isSvgRoot = true;
      node.svgRootViewBox[0] = (float)pp->minX;
      node.svgRootViewBox[1] = (float)pp->minY;
      node.svgRootViewBox[2] = (float)pp->vbWidth;
      node.svgRootViewBox[3] = (float)pp->vbHeight;
      // ⚠️ A ZERO-OR-NEGATIVE EXTENT MEANS "NO viewBox DECLARED", NOT "SCALE BY
      // ZERO". rnsvg default-initialises all four to 0.0, so an <Svg> with no
      // viewBox at all is indistinguishable from one declaring an empty box.
      // Dividing here would map every coordinate to infinity and paint
      // nothing -- the silent-blank failure this file keeps producing. The
      // painter is gated on this flag and falls back to raw user units, which
      // is exactly what SVG specifies for a missing viewBox.
      node.svgRootHasViewBox =
          node.svgRootViewBox[2] > 0.0f && node.svgRootViewBox[3] > 0.0f;
      node.svgRootAlign = pp->align;
      node.svgRootMeetOrSlice = pp->meetOrSlice;
    }
  } else if (node.componentName == "RNSVGDefs" ||
             node.componentName == "RNSVGClipPath" ||
             node.componentName == "RNSVGMask") {
    // Containers that DECLARE. See SceneNode::isSvgDefinition -- without this
    // the painter walks straight into their children and draws the definition
    // at its own coordinates.
    node.isSvgDefinition = true;
  } else if (node.componentName == "RNSVGSymbol") {
    node.isSvgDefinition = true;
    if (const auto* pp =
            dynamic_cast<const react::RNSVGSymbolProps*>(view.props.get())) {
      node.svgDefName = pp->name;
      node.svgSymbolViewBox[0] = (float)pp->minX;
      node.svgSymbolViewBox[1] = (float)pp->minY;
      node.svgSymbolViewBox[2] = (float)pp->vbWidth;
      node.svgSymbolViewBox[3] = (float)pp->vbHeight;
    }
  } else if (node.componentName == "RNSVGUse") {
    if (const auto* pp =
            dynamic_cast<const react::RNSVGUseProps*>(view.props.get())) {
      node.isSvgUse = true;
      // ⚠️ `href` ARRIVES ALREADY STRIPPED OF ITS '#'. I asserted the opposite
      // and was wrong; the mutation run caught it. elements/Use.js matches
      // `href` against idPattern = /#([^)]+)'?\)?$/ and forwards CAPTURE GROUP
      // 1, so "#hostapp-sig" reaches C++ as "hostapp-sig". (A gradient's brushRef is
      // stripped the same way, by extractBrush -- the two are consistent, which
      // is the opposite of what the comment here used to claim.)
      //
      // The defensive strip below is therefore a no-op today and is kept only
      // because xlinkHref and a future non-JS caller could bypass that path. It
      // is NOT load-bearing, and mutation-verify-usesym.sh deliberately does not
      // pretend it is: a mutant removing it SURVIVES, correctly.
      node.svgUseHref = pp->href;
      if (!node.svgUseHref.empty() && node.svgUseHref[0] == '#') {
        node.svgUseHref.erase(0, 1);
      }
      node.svgUseBox[0] = svgLength(pp->x);
      node.svgUseBox[1] = svgLength(pp->y);
      node.svgUseBox[2] = svgLength(pp->width, -1.0f);
      node.svgUseBox[3] = svgLength(pp->height, -1.0f);
      node.svgUseHasSize = node.svgUseBox[2] > 0.0f && node.svgUseBox[3] > 0.0f;
      // A <Use> carries the full renderable prop set and its fill/stroke
      // CASCADE into the instance, so read them like any other shape.
      readSvgPaintProps(node, pp);
    }
  } else if (node.componentName == "RNSVGLinearGradient" ||
             node.componentName == "RNSVGRadialGradient") {
    // ⛔ A GRADIENT DEF PAINTS NOTHING ITSELF. It is a definition consumed by
    // whichever shape references it with fill="url(#id)" -- and it usually
    // sits inside <Defs>, which is not even in the paint order. So this branch
    // only RECORDS it; SceneGraph::paint resolves references against the
    // registry built from these nodes.
    node.isSvgGradient = true;
    node.svgGradientRadial = (node.componentName == "RNSVGRadialGradient");
    if (const auto* lg = dynamic_cast<const react::RNSVGLinearGradientProps*>(
            view.props.get())) {
      node.svgGradientName = lg->name;
      node.svgGradientStops.assign(lg->gradient.begin(), lg->gradient.end());
      node.svgGradientCoords[0] = svgLength(lg->x1);
      node.svgGradientCoords[1] = svgLength(lg->y1);
      node.svgGradientCoords[2] = svgLength(lg->x2, 1.0f);
      node.svgGradientCoords[3] = svgLength(lg->y2);
      node.svgGradientUnits = lg->gradientUnits;
    } else if (const auto* rg =
                   dynamic_cast<const react::RNSVGRadialGradientProps*>(
                       view.props.get())) {
      node.svgGradientName = rg->name;
      node.svgGradientStops.assign(rg->gradient.begin(), rg->gradient.end());
      node.svgGradientCoords[0] = svgLength(rg->fx, 0.5f);
      node.svgGradientCoords[1] = svgLength(rg->fy, 0.5f);
      node.svgGradientCoords[2] = svgLength(rg->rx, 0.5f);
      node.svgGradientCoords[3] = svgLength(rg->ry, 0.5f);
      node.svgGradientCoords[4] = svgLength(rg->cx, 0.5f);
      node.svgGradientCoords[5] = svgLength(rg->cy, 0.5f);
      node.svgGradientUnits = rg->gradientUnits;
    }
  } else if (node.componentName == "world") {
    // <world> ENG-09. Borrows RNSVGImageProps (see fabric/WorldShadowNode.h
    // for why) -- `name` is the only field this node reads; it is the SAME
    // string JS passes as WorldRaster.setPixels(id, ...)'s `id`.
    node.isWorldRaster = true;
    if (const auto* pp =
            dynamic_cast<const react::RNSVGImageProps*>(view.props.get())) {
      node.worldRasterName = pp->name;
    }
  }

#endif
}

void SceneGraph::applyMutations(
    const react::ShadowViewMutation::List& mutations, bool log) {
  std::lock_guard<std::mutex> lock(mutex_);
  for (const auto& m : mutations) {
    switch (m.type) {
      case react::ShadowViewMutation::Create: {
        SceneNode node;
        updateFromShadowView(node, m.newChildShadowView);
        nodes_[node.tag] = std::move(node);
        if (log) {
          std::printf("[fabric] CREATE tag=%d type=%s\n",
                      m.newChildShadowView.tag,
                      m.newChildShadowView.componentName);
        }
        break;
      }
      case react::ShadowViewMutation::Delete: {
        nodes_.erase(m.oldChildShadowView.tag);
        if (log) {
          std::printf("[fabric] DELETE tag=%d\n", m.oldChildShadowView.tag);
        }
        break;
      }
      case react::ShadowViewMutation::Insert: {
        auto childTag = m.newChildShadowView.tag;
        if (auto it = nodes_.find(childTag); it != nodes_.end()) {
          updateFromShadowView(it->second, m.newChildShadowView);
          it->second.parent = m.parentTag;
        }
        if (m.parentTag == 0) {
          // A surface's root has no parent mutation; track it as a root.
          if (std::find(roots_.begin(), roots_.end(), childTag) == roots_.end()) {
            roots_.push_back(childTag);
          }
        } else if (auto p = nodes_.find(m.parentTag); p != nodes_.end()) {
          auto& kids = p->second.children;
          auto idx = (size_t)std::max(0, m.index);
          kids.insert(kids.begin() + (long)std::min(idx, kids.size()), childTag);
        }
        if (log) {
          const auto& f = m.newChildShadowView.layoutMetrics.frame;
          std::printf(
              "[fabric] INSERT tag=%d type=%s parent=%d index=%d frame={%.1f,%.1f %.1fx%.1f}\n",
              childTag, m.newChildShadowView.componentName, m.parentTag, m.index,
              (double)f.origin.x, (double)f.origin.y, (double)f.size.width,
              (double)f.size.height);
        }
        break;
      }
      case react::ShadowViewMutation::Remove: {
        auto childTag = m.oldChildShadowView.tag;
        if (auto p = nodes_.find(m.parentTag); p != nodes_.end()) {
          auto& kids = p->second.children;
          kids.erase(std::remove(kids.begin(), kids.end(), childTag), kids.end());
        }
        roots_.erase(std::remove(roots_.begin(), roots_.end(), childTag),
                     roots_.end());
        if (log) {
          std::printf("[fabric] REMOVE tag=%d parent=%d\n", childTag, m.parentTag);
        }
        break;
      }
      case react::ShadowViewMutation::Update: {
        auto tag = m.newChildShadowView.tag;
        // ⛔ Upsert, NOT a find-and-modify. The SURFACE ROOT is created by
        // Fabric itself, so the scene graph never sees a Create for it — its
        // first and only appearance is an UPDATE carrying the root's frame.
        // With a plain find(), the root is never inserted, `roots_` stays
        // empty, paint() walks nothing, and every child mounts correctly into
        // a tree with no entry point. Symptom: scene_nodes>0, painted_nodes=0.
        auto& node = nodes_[tag];
        updateFromShadowView(node, m.newChildShadowView);
        if (log) {
          const auto& f = m.newChildShadowView.layoutMetrics.frame;
          std::printf("[fabric] UPDATE tag=%d type=%s frame={%.1f,%.1f %.1fx%.1f}\n",
                      tag, m.newChildShadowView.componentName,
                      (double)f.origin.x, (double)f.origin.y,
                      (double)f.size.width, (double)f.size.height);
        }
        break;
      }
    }
  }
  if (log) std::fflush(stdout);

  // Root adoption. A node is a root when nothing ever inserted it into a
  // parent — which for the surface root is the normal case (see the Update
  // upsert above). Keyed on parent==0 rather than on the component NAME,
  // because a name check ("RootView") silently stops working the moment a
  // surface roots something else, and the failure is again a blank frame.
  for (auto& [tag, node] : nodes_) {
    if (node.parent == 0 &&
        std::find(roots_.begin(), roots_.end(), tag) == roots_.end()) {
      roots_.push_back(tag);
    }
  }
  // ...and drop roots that have since been given a parent, so a re-parented
  // node is not painted twice (once as a root, once as a child).
  roots_.erase(std::remove_if(roots_.begin(), roots_.end(),
                              [this](facebook::react::Tag t) {
                                auto it = nodes_.find(t);
                                return it == nodes_.end() || it->second.parent != 0;
                              }),
               roots_.end());
  // P12-01: a mounting transaction is scene damage. Bump the revision so the
  // windowed idle-skip loop repaints, and WAKE it if it is asleep in
  // glfwWaitEventsTimeout — applyMutations runs on the JS thread, so without the
  // wake a commit here would not paint until the next unrelated input. Called
  // while mutex_ is still held: bumpVersion takes only wakeMutex_, never mutex_,
  // so there is no lock-order inversion.
  bumpVersion();
}

// ── Idle-frame damage signal + wake (P12-01) ────────────────────────────────
void SceneGraph::bumpVersion() {
  version_.fetch_add(1, std::memory_order_release);
  std::function<void()> wake;
  {
    std::lock_guard<std::mutex> lock(wakeMutex_);
    wake = damageWake_;  // copy under the wake lock; never call it while held
  }
  if (wake) wake();
}

void SceneGraph::setDamageWake(std::function<void()> wake) {
  std::lock_guard<std::mutex> lock(wakeMutex_);
  damageWake_ = std::move(wake);
}

// ENG-06. The direct-manipulation prop path -- see the comment on the
// declaration in SceneGraph.h for why animation does not use mounting
// transactions.
//
// ⛔ WHY THIS IS A HAND-WRITTEN KEY SWITCH AND NOT A ViewProps CONSTRUCTION.
// The payload is a PARTIAL dynamic: {"opacity": 0.37} and nothing else. Round-
// tripping it through ViewProps would fill every key the caller did NOT send
// with prop DEFAULTS and then write all of them onto the node -- so animating
// opacity would silently reset backgroundColor, borders and the transform to
// their defaults. The bug that produces is a view that goes transparent and
// loses its background at the same time, which reads as a paint bug.
//
// Unknown keys are IGNORED ON PURPOSE but are not silent: they do not increment
// the applied counter, so a gate asserting directPropUpdates_ > 0 goes red when
// a future RN drives a prop shape this switch does not know. Unsupported and
// unnoticed are different things.
bool SceneGraph::updateViewProps(facebook::react::Tag tag,
                                 const folly::dynamic& props) {
  std::lock_guard<std::mutex> lock(mutex_);
  const unsigned long before = directPropUpdates_;
  auto it = nodes_.find(tag);
  if (it == nodes_.end()) {
    return false;
  }
  SceneNode& node = it->second;
  if (!props.isObject()) {
    return true;
  }

  for (const auto& entry : props.items()) {
    if (!entry.first.isString()) continue;
    const auto key = entry.first.asString();
    const folly::dynamic& value = entry.second;

    if (key == "opacity") {
      // By VALUE, never by storage class: JSON has one number type and folly
      // picks int64 for a whole 0 or 1 and double for everything between, so
      // an isDouble() guard drops exactly the endpoints of every 0->1 ramp.
      if (!value.isNumber()) continue;
      node.opacity = (float)value.asDouble();
      ++directPropUpdates_;
      continue;
    }

    if (key == "transform") {
      // RN sends the resolved 4x4 as a flat 16-element array, column-major,
      // the same layout SceneNode::transform already holds.
      if (!value.isArray() || value.size() != 16) continue;
      std::array<float, 16> m{};
      bool ok = true;
      for (size_t i = 0; i < 16 && ok; ++i) {
        if (!value[i].isNumber()) { ok = false; break; }
        m[i] = (float)value[i].asDouble();
      }
      // ⛔ STAGE THEN COMMIT. Writing straight into node.transform and bailing
      // partway through a malformed array would leave the node holding half a
      // new matrix and half the old one -- not identity, not the previous
      // transform, and not anything the caller sent.
      if (!ok) continue;
      node.transform = m;
      ++directPropUpdates_;
      continue;
    }
  }
  // P12-01: a NativeAnimated opacity/transform ramp bypasses the shadow tree
  // and lands here every frame on the JS thread. If any prop actually applied,
  // it is scene damage: bump + wake so the idle-skip loop presents this tick
  // instead of freezing the animation on the last painted frame. Bumped only on
  // a real apply, so a call that matched no known key does not falsely wake.
  if (directPropUpdates_ != before) bumpVersion();
  return true;
}

namespace {
// parity item 8. RN (like CSS) applies `opacity` to a view AND its subtree,
// composited as ONE group: a child under an opacity:0 parent is invisible,
// and two overlapping opaque children under opacity:0.5 show the top child
// at 50% over the background, not over the bottom child. A node with
// children and opacity < 1 therefore paints into a save-layer composited at
// its opacity; inside it, its own draws use alpha 1 (the layer applies the
// opacity once). A LEAF keeps the cheaper per-draw alpha, which is exact for
// a single draw.
bool UsesOpacityLayer(const SceneNode& n) {
  return n.opacity < 0.999f && !n.children.empty();
}
float OwnAlpha(const SceneNode& n) {
  return UsesOpacityLayer(n) ? 1.0f : n.opacity;
}

// P1 item 15: the string a paragraph PAINTS, i.e. its runs joined (each run
// already carries its own textTransform). Selection offsets index this.
std::string JoinRuns(const SceneNode& n) {
  std::string s;
  for (const TextRun& r : n.runs) s += r.text;
  return s;
}

// P1 item 15: the grapheme cluster's bounds in PARAGRAPH space. Impeller's
// interop (impeller/toolkit/interop/glyph_info.cc, SDK 114eb18 and upstream
// master as of 2026-10) builds the rect as {bounds.y(), bounds.x(), w, h}:
// x and y arrive SWAPPED. Measured on 'SELECT ME' at 32 pt: r.x stays 0.1
// for every glyph while r.y steps 0, 16.8, 34.7 ... Un-swap here, in ONE
// place, so the highlight and the press->offset mapping agree. If an SDK
// bump fixes the swap, ci-style-audit tile `select` fails (highlight turns
// into a 1-glyph-wide column) and this is the line to delete.
ImpellerRect ClusterBounds(ImpellerGlyphInfo gi) {
  ImpellerRect r{};
  ImpellerGlyphInfoGetGraphemeClusterBounds(gi, &r);
  return ImpellerRect{r.y, r.x, r.width, r.height};
}

// UTF-8 byte offset -> UTF-16 code-unit index (Impeller's paragraph indexes
// glyphs in UTF-16 units). A 4-byte sequence is a surrogate pair (2 units).
size_t Utf8ToUtf16Index(const std::string& s, size_t byteOff) {
  size_t units = 0;
  for (size_t i = 0; i < byteOff && i < s.size();) {
    const unsigned char c = (unsigned char)s[i];
    const size_t len = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3 : 4;
    units += len == 4 ? 2 : 1;
    i += len;
  }
  return units;
}

// Inverse: UTF-16 index -> UTF-8 byte offset, clamped, on a codepoint boundary.
size_t Utf16ToUtf8Index(const std::string& s, size_t units) {
  size_t i = 0, u = 0;
  while (i < s.size() && u < units) {
    const unsigned char c = (unsigned char)s[i];
    const size_t len = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3 : 4;
    u += len == 4 ? 2 : 1;
    i += len;
  }
  return std::min(i, s.size());
}

// ENG-24. Where the caret sits in a laid-out TextInput paragraph, in
// paragraph coordinates: the LINE holding the UTF-8 offset (a hard newline or
// a soft wrap moves it to the next line's start), and the x just after the
// cluster before it. Shared by the painter and the content-size report so the
// caret, the scroll-follow and onContentSizeChange read one layout.
struct TiCaret {
  float x = 0.0f, y = 0.0f, h = 0.0f;
};
TiCaret TextInputCaretAt(ImpellerParagraph par, const std::string& s,
                         size_t byteOff, float fallbackH) {
  TiCaret c;
  c.h = fallbackH;
  const size_t u16 = Utf8ToUtf16Index(s, byteOff);
  ImpellerLineMetrics lm = ImpellerParagraphGetLineMetrics(par);  // borrowed
  const uint32_t n = ImpellerParagraphGetLineCount(par);
  if (lm == nullptr || n == 0) return c;
  // The line whose [start, end-including-newline) holds code unit `u`.
  // Matched on the END index: Skia reports the empty line after a trailing
  // '\n' with a start index one short (measured: "a\n" -> line 1 start=1),
  // so "the last line starting at or before u" picks the wrong line.
  auto lineOf = [&](size_t u, uint32_t* out) -> bool {
    for (uint32_t i = 0; i < n; ++i) {
      if (ImpellerLineMetricsGetCodeUnitStartIndex(lm, i) <= u &&
          u < ImpellerLineMetricsGetCodeUnitEndIndexIncludingNewline(lm, i)) {
        *out = i;
        return true;
      }
    }
    return false;
  };
  auto place = [&](uint32_t line) {
    const float asc = (float)ImpellerLineMetricsGetAscent(lm, line);
    const float desc = (float)ImpellerLineMetricsGetDescent(lm, line);
    c.y = (float)ImpellerLineMetricsGetBaseline(lm, line) - asc;
    if (asc + desc > 0.0f) c.h = asc + desc;
  };
  if (u16 == 0) {
    place(0);
    c.x = (float)ImpellerLineMetricsGetLeft(lm, 0);
    return c;
  }
  // Right after a hard newline: the start of the line below the one that
  // holds the '\n' (one line height down when the layout has no such line).
  if (byteOff <= s.size() && s[byteOff - 1] == '\n') {
    uint32_t nl = 0;
    if (!lineOf(u16 - 1, &nl)) nl = n - 1;
    if (nl + 1 < n) {
      place(nl + 1);
      c.x = (float)ImpellerLineMetricsGetLeft(lm, nl + 1);
    } else {
      place(nl);
      c.y += (float)ImpellerLineMetricsGetHeight(lm, nl);
      c.x = 0.0f;
    }
    return c;
  }
  // A caret ON a line's first code unit (a soft-wrap start) sits at that
  // line's left edge; anywhere else, just after the cluster before it, on
  // that cluster's line.
  uint32_t line = 0;
  if (u16 < Utf8ToUtf16Index(s, s.size()) && lineOf(u16, &line) &&
      ImpellerLineMetricsGetCodeUnitStartIndex(lm, line) == u16) {
    place(line);
    c.x = (float)ImpellerLineMetricsGetLeft(lm, line);
    return c;
  }
  if (!lineOf(u16 - 1, &line)) line = n - 1;
  place(line);
  ImpellerGlyphInfo gi =
      ImpellerParagraphCreateGlyphInfoAtCodeUnitIndexNew(par, u16 - 1);
  if (gi != nullptr) {
    const ImpellerRect r = ClusterBounds(gi);
    c.x = r.x + r.width;
    ImpellerGlyphInfoRelease(gi);
  }
  return c;
}

// ENG-24. The width a TextInput's text lays out in: a multiline field wraps
// inside its box; a single-line field never wraps (it scrolls sideways).
float TextInputWrapWidth(bool multiline, float boxW, float padL, float padR) {
  if (!multiline) return 1e6f;
  return boxW > padL + padR + 1.0f ? boxW - padL - padR : 1.0f;
}

// SC-02: a TextInput's text inset: the default pad plus padding + border
// (contentInsets). One source for paint, caret, click, selection and wrap.
float TextInputPadL(const SceneNode& node) {
  return kTextInputPad + (float)node.layoutMetrics.contentInsets.left;
}
float TextInputPadR(const SceneNode& node) {
  return kTextInputPad + (float)node.layoutMetrics.contentInsets.right;
}

// ENG-25. ONE paragraph for a TextInput's text: what paint draws, and (for a
// multiline field) what the caret, the click hit test, the selection rects
// and Up/Down read. Wrapped at the field width minus the text inset. `fg`
// may be null: colour does not change layout.
//
// Before ENG-25 only the PAINT wrapped. The caret and the click mapping
// measured an UNWRAPPED prefix (wrap width 1e6), so in a multiline field the
// glyphs wrapped to the box while the caret walked off its right edge on
// line 1, and a click on wrapped line 2 landed on line 1.
ImpellerParagraph BuildTextInputParagraph(ImpellerTypographyContext typo,
                                          const SceneNode& node,
                                          const std::string& text, float w,
                                          ImpellerPaint fg) {
  ImpellerParagraphStyle style = ImpellerParagraphStyleNew();
  ImpellerParagraphStyleSetFontSize(style, node.fontSize);
  ApplyFontFamily(style, node.fontFamily);  // ENG-22
  ApplyLineHeight(style, node.lineHeight, node.fontSize);  // ENG-23 TextInput
  rni::ApplyTextInputFace(style, node.tiFace, node.tiMultiline);  // SC-20
  if (fg != nullptr) {
    ImpellerParagraphStyleSetForeground(style, fg);
    const float* dc = node.tiFace.hasDecoColor ? node.tiFace.decoColor : node.textColor;
    rni::ApplyTextDecoration(style, node.tiFace.decoLine, node.tiFace.decoStyle,
                             impellerColor(dc, OwnAlpha(node)));
  }
  const std::string shownText = rni::applyTextTransform(text, node.tiFace.transform);
  ImpellerParagraphBuilder pb = ImpellerParagraphBuilderNew(typo);
  ImpellerParagraphBuilderPushStyle(pb, style);
  ImpellerParagraphBuilderAddText(pb, (const uint8_t*)shownText.data(), shownText.size());
  ImpellerParagraph par = ImpellerParagraphBuilderBuildParagraphNew(
      pb, TextInputWrapWidth(node.tiMultiline, w, TextInputPadL(node),
                         TextInputPadR(node)));  // ENG-24
  ImpellerParagraphBuilderRelease(pb);
  ImpellerParagraphStyleRelease(style);
  return par;
}

// SC-20: a single-line field is laid out unwrapped (width 1e6), so textAlign
// centre/right becomes a shift of the whole line inside the content box. Text
// wider than the box gets 0 (it scrolls). Multiline fields align per line in
// the paragraph itself. `text` is what paints (the placeholder when empty).
float TextInputAlignDx(ImpellerTypographyContext typo, const SceneNode& node,
                       const std::string& text, float w) {
  const int a = node.tiFace.align;
  if (node.tiMultiline || (a != 2 && a != 3) || text.empty()) return 0.0f;
  ImpellerParagraph par = BuildTextInputParagraph(typo, node, text, w, nullptr);
  if (par == nullptr) return 0.0f;
  const float tw = ImpellerParagraphGetMaxIntrinsicWidth(par);
  ImpellerParagraphRelease(par);
  // The 1 pt caret bar must fit after right-aligned text.
  const float extra = w - TextInputPadL(node) - TextInputPadR(node) - 1.0f - tw;
  if (extra <= 0.0f) return 0.0f;
  return a == 2 ? extra * 0.5f : extra;
}

// ENG-23 (TextInput): one line's height with no paragraph to read it from
// (empty field, single-line centring, the caret line). lineHeight when set,
// else the face's ~1.2 em that every TextInput path used before.
float TextInputLineH(const SceneNode& node) {
  return node.lineHeight > 0.0f ? node.lineHeight : node.fontSize * 1.2f;
}

// ENG-16 + ENG-25: y of a TextInput's first line, for paint AND hit test.
// `drawStr` is what paints (the placeholder when the field is empty).
float TextInputTextTop(ImpellerTypographyContext typo, const SceneNode& node,
                       float y, float w, float h, const std::string& drawStr) {
  const float lineH = TextInputLineH(node);  // ENG-23 TextInput
  // A multiline value can wrap or hold newlines: bottom/center must place
  // the WHOLE text block, so measure it (same face, same wrap width).
  float blockH = lineH;
  if (node.tiMultiline && !drawStr.empty() && node.tiAlignVertical >= 2) {
    ImpellerParagraph mp = BuildTextInputParagraph(typo, node, drawStr, w, nullptr);
    if (mp != nullptr) {
      blockH = std::max(lineH, (float)ImpellerParagraphGetHeight(mp));
      ImpellerParagraphRelease(mp);
    }
  }
  const auto& insets = node.layoutMetrics.contentInsets;
  return TextInputLineTop(y, h, blockH, (float)insets.top, (float)insets.bottom,
                          node.tiMultiline, node.tiAlignVertical);
}

// ENG-25. One wrapped line, from the paragraph's own line metrics, in
// paragraph space. Line L OWNS caret positions [start16_L, start16_{L+1});
// the last line also owns the end. So a position on a soft-wrap boundary
// paints at the START of the next line (where the next typed glyph goes).
struct TiLine {
  size_t start16 = 0;
  float top = 0.0f, height = 0.0f, left = 0.0f, width = 0.0f;
};

std::vector<TiLine> TiLinesOf(ImpellerParagraph par, const std::string& shown,
                              float fallbackH) {
  std::vector<TiLine> out;
  const uint32_t n = ImpellerParagraphGetLineCount(par);
  // Owned by the paragraph (cached with it): never released here.
  ImpellerLineMetrics lm = ImpellerParagraphGetLineMetrics(par);
  for (uint32_t i = 0; lm != nullptr && i < n; ++i) {
    TiLine l;
    l.start16 = ImpellerLineMetricsGetCodeUnitStartIndex(lm, i);
    // ENG-24 x ENG-25: a line never starts before the previous line ends
    // (newline included). Skia reports the empty line after a trailing '\n'
    // with a start index one short (measured: "a\n" -> line 1 start=1), which
    // made the end position look unowned and pushed the caret a line too far.
    if (i > 0) {
      l.start16 = std::max(
          l.start16,
          (size_t)ImpellerLineMetricsGetCodeUnitEndIndexIncludingNewline(lm, i - 1));
    }
    l.top = (float)(ImpellerLineMetricsGetBaseline(lm, i) -
                    std::fabs(ImpellerLineMetricsGetAscent(lm, i)));
    l.height = (float)ImpellerLineMetricsGetHeight(lm, i);
    l.left = (float)ImpellerLineMetricsGetLeft(lm, i);
    l.width = (float)ImpellerLineMetricsGetWidth(lm, i);
    out.push_back(l);
  }
  if (out.empty()) {
    TiLine l;
    l.height = fallbackH;
    out.push_back(l);
  }
  // A trailing '\n' puts the caret after it on an empty line BELOW. If the
  // layout did not emit that line, add it so the end position has one.
  const size_t len16 = Utf8ToUtf16Index(shown, shown.size());
  if (!shown.empty() && shown.back() == '\n' && out.back().start16 < len16) {
    TiLine l;
    l.start16 = len16;
    l.top = out.back().top + out.back().height;
    l.height = out.back().height;
    out.push_back(l);
  }
  return out;
}

size_t TiLineIndex(const std::vector<TiLine>& lines, size_t p16) {
  size_t L = 0;
  for (size_t i = 1; i < lines.size() && lines[i].start16 <= p16; ++i) L = i;
  return L;
}

// Paragraph-space x of the caret at byte offset `m8` of `shown`, which sits
// on `line`. Line start = the line's left edge; otherwise the right edge of
// the grapheme cluster that ends at the caret, read from the wrapped layout.
float TiCaretX(ImpellerParagraph par, const TiLine& line,
               const std::string& shown, size_t m8) {
  if (m8 == 0 || Utf8ToUtf16Index(shown, m8) <= line.start16) return line.left;
  size_t prev = std::min(m8, shown.size()) - 1;
  while (prev > 0 && (((unsigned char)shown[prev]) & 0xC0) == 0x80) --prev;
  ImpellerGlyphInfo gi = ImpellerParagraphCreateGlyphInfoAtCodeUnitIndexNew(
      par, Utf8ToUtf16Index(shown, prev));
  if (gi == nullptr) return line.left;
  const ImpellerRect r = ClusterBounds(gi);
  ImpellerGlyphInfoRelease(gi);
  return r.x + r.width;
}

// ENG-25. Every caret position of a MULTILINE field in SCREEN space: source
// byte offset, x, and the wrapped line it sits on. Shared by the click hit
// test, drag, Up/Down and the ti_glyph_x report, so they cannot disagree.
struct TiGeom {
  std::vector<TiLine> lines;
  std::vector<size_t> offsets;  // SOURCE byte offsets (raw, not the mask)
  std::vector<float> xs;        // screen x of each
  std::vector<size_t> line;     // line index of each
  float textX = 0.0f, textY = 0.0f;
};

bool TiGeomOf(ImpellerTypographyContext typo, const SceneNode& node,
              const std::string& raw, float ox, float oy, float scrollY,
              TiGeom* g) {
  const std::string shown = node.tiSecure ? SecureMask(raw) : raw;
  const bool showPlaceholder = shown.empty() && !node.tiPlaceholder.empty();
  const float w = (float)node.layoutMetrics.frame.size.width;
  const float h = (float)node.layoutMetrics.frame.size.height;
  g->textX = ox + TextInputPadL(node);
  // ENG-24: a focused multiline field may be scrolled vertically.
  g->textY = TextInputTextTop(typo, node, oy, w, h,
                              showPlaceholder ? node.tiPlaceholder : shown) -
             scrollY;
  const float lineH = TextInputLineH(node);  // ENG-23 TextInput
  ImpellerParagraph par =
      shown.empty() ? nullptr : BuildTextInputParagraph(typo, node, shown, w, nullptr);
  if (par != nullptr) {
    g->lines = TiLinesOf(par, shown, lineH);
  } else {
    TiLine l;
    l.height = lineH;
    g->lines.push_back(l);
  }
  for (size_t i = 0; i <= raw.size(); ++i) {
    if (i > 0 && i < raw.size() && (((unsigned char)raw[i]) & 0xC0) == 0x80) continue;
    const size_t mi = node.tiSecure ? SecureMaskOffset(raw, i) : i;
    const size_t L = TiLineIndex(g->lines, Utf8ToUtf16Index(shown, mi));
    g->offsets.push_back(i);
    g->line.push_back(L);
    g->xs.push_back(g->textX +
                    (par != nullptr ? TiCaretX(par, g->lines[L], shown, mi)
                                    : g->lines[L].left));
  }
  if (par != nullptr) ImpellerParagraphRelease(par);
  return true;
}

// The boundary on line `L` nearest screen x `x` (index into g.offsets).
size_t TiNearestOnLine(const TiGeom& g, size_t L, float x) {
  size_t best = SIZE_MAX;
  float bestD = 0.0f;
  for (size_t i = 0; i < g.offsets.size(); ++i) {
    if (g.line[i] != L) continue;
    const float d = std::fabs(x - g.xs[i]);
    if (best == SIZE_MAX || d < bestD) {
      best = i;
      bestD = d;
    }
  }
  return best == SIZE_MAX ? 0 : best;
}
}  // namespace

// P1 item 14: one style push per run, mirroring ImpellerTextLayoutManager
// fragment for fragment, so measure and paint agree on every run's size, face,
// weight and pitch. Paragraph-level settings (alignment, clamp, ellipsis) ride
// on EVERY run's style: Impeller takes them from the first style on the stack,
// and measure sets the clamp on every run the same way. Item 15's hit mapping
// builds through here too, so a point maps to the glyph PAINTED there.
// textAlignVertical / verticalAlign: the glyphs sit at the top, middle or
// bottom of a content box taller than the text (Android semantics).
static float ParagraphVOffset(const SceneNode& node, ImpellerParagraph paragraph, float boxH) {
  const float spare = boxH - ImpellerParagraphGetHeight(paragraph);
  if (spare <= 0.0f) return 0.0f;
  if (node.textVAlign == 3) return spare * 0.5f;
  if (node.textVAlign == 2) return spare;
  return 0.0f;
}

static bool SameShadow(const TextRun& a, const TextRun& b) {
  return a.hasShadow && b.hasShadow && a.shadowOffX == b.shadowOffX && a.shadowOffY == b.shadowOffY &&
         a.shadowSigma == b.shadowSigma && std::equal(a.shadowColor, a.shadowColor + 4, b.shadowColor);
}

static std::vector<TextRun> ScaleRuns(const std::vector<TextRun>& runs, float s) {
  std::vector<TextRun> out = runs;
  for (TextRun& r : out) {
    r.fontSize *= s;
    r.lineHeight *= s;
  }
  return out;
}

ImpellerParagraph SceneGraph::buildRunParagraph(const SceneNode& node, float w, int shadow) {
  // SC-17: shrink every run by the factor measure found for this width.
  if (node.adjustsFit) {
    const auto shape = [&](float s) {
      SceneNode plain = node;
      plain.maxLines = 0;
      plain.adjustsFit = false;
      plain.ellipsizeMode = 0;
      plain.runs = ScaleRuns(node.runs, s);
      ImpellerParagraph p = buildRunParagraphFrom(plain, plain.runs, w, -1);
      std::pair<int, float> r{0, 0.0f};
      if (p) {
        r = {(int)ImpellerParagraphGetLineCount(p), ImpellerParagraphGetLongestLineWidth(p)};
        ImpellerParagraphRelease(p);
      }
      return r;
    };
    const float s = rni::FitFontScale(true, node.minFontScale, node.maxLines, w, shape);
    if (s < 1.0f) {
      SceneNode scaled = node;
      scaled.adjustsFit = false;
      scaled.runs = ScaleRuns(node.runs, s);
      return buildRunParagraph(scaled, w, shadow);
    }
  }
  // SC-16: Impeller only truncates at the tail, so head/middle are cut by hand.
  if (node.maxLines == 1 && (node.ellipsizeMode == 1 || node.ellipsizeMode == 3)) {
    const auto widthOf = [&](const std::vector<TextRun>& r) {
      ImpellerParagraph p = buildRunParagraphFrom(node, r, 1e6f, -1);
      const float lw = p ? ImpellerParagraphGetLongestLineWidth(p) : 0.0f;
      if (p) ImpellerParagraphRelease(p);
      return lw;
    };
    const std::vector<TextRun> cut = rni::EllipsizeRuns(node.runs, node.ellipsizeMode, w, widthOf);
    return buildRunParagraphFrom(node, cut, w, shadow);
  }
  return buildRunParagraphFrom(node, node.runs, w, shadow);
}

ImpellerParagraph SceneGraph::buildRunParagraphFrom(const SceneNode& node, const std::vector<TextRun>& runs,
                                                    float w, int shadow) {
  if (typography_ == nullptr) return nullptr;
  std::vector<ImpellerPaint> runPaints;
  ImpellerParagraphBuilder pb = ImpellerParagraphBuilderNew(typography_);
  if (pb == nullptr) return nullptr;
  for (const TextRun& run : runs) {
    if (run.text.empty()) continue;
    ImpellerParagraphStyle style = ImpellerParagraphStyleNew();
    ImpellerParagraphStyleSetFontSize(style, run.fontSize);
    ApplyFontFamily(style, run.fontFamily);  // ENG-22
    ApplyLineHeight(style, run.lineHeight, run.fontSize);  // ENG-23
    // Style audit items 5, 7 (text/TextStyle.h). Weight is measured too.
    ApplyFontWeight(style, run.fontWeight);
    ApplyTextAlign(style, node.textAlign);
    ApplyFontStyle(style, run.italic);
    ApplyTextDirection(style, node.writingDirection);
    if (node.maxLines > 0) {
      // Painting must honour the same clamp measurement did, or a
      // numberOfLines={1} label is measured at one line and painted at
      // three, overflowing whatever sits below it.
      ImpellerParagraphStyleSetMaxLines(style, (uint32_t)node.maxLines);
      // ⛔ ELLIPSIS ONLY MAKES SENSE ON A CLAMPED PARAGRAPH. RN's
      // EllipsizeMode: 0 Clip (hard cut, NO ellipsis string), 1 Head,
      // 2 Tail (RN default), 3 Middle. Impeller's C API exposes one ellipsis
      // STRING, not a position, so Head/Tail/Middle all truncate at the tail.
      if (node.ellipsizeMode != 0) {
        ImpellerParagraphStyleSetEllipsis(style, "\xE2\x80\xA6");  // U+2026 …
      }
    }
    ImpellerPaint textPaint = ImpellerPaintNew();
    ImpellerColor tc = impellerColor(run.color, OwnAlpha(node) * run.opacity);
    // Shadow silhouette: opaque for this group's runs, invisible for the rest.
    const bool shadowRun = shadow >= 0 && SameShadow(run, runs[shadow]);
    if (shadow >= 0) tc.alpha = shadowRun ? 1.0f : 0.0f;
    ImpellerPaintSetColor(textPaint, &tc);
    ImpellerParagraphStyleSetForeground(style, textPaint);
    runPaints.push_back(textPaint);
    // A nested <Text style={{backgroundColor}}> fills behind its own glyphs
    // only (RN iOS NSBackgroundColorAttributeName), not the whole line box.
    if (run.hasBackground && shadow < 0) {
      ImpellerPaint bgPaint = ImpellerPaintNew();
      ImpellerColor bc = impellerColor(run.background, OwnAlpha(node) * run.opacity);
      ImpellerPaintSetColor(bgPaint, &bc);
      ImpellerParagraphStyleSetBackground(style, bgPaint);
      runPaints.push_back(bgPaint);
    }
    // Style audit item 9: decoration colour defaults to the run's colour.
    ImpellerColor decoC = impellerColor(run.hasDecoColor ? run.decoColor : run.color,
                                        OwnAlpha(node) * run.opacity);
    if (shadow >= 0) decoC.alpha = shadowRun ? 1.0f : 0.0f;
    ApplyTextDecoration(style, run.decoLine, run.decoStyle, decoC);
    // SC-19: one push per fallback segment (text/FontFallback.h); same split in measure.
    const std::string primary = run.fontFamily.empty() ? "" : rni::ResolveFontFamily(run.fontFamily);
    const std::vector<rni::FontSegment> segs = rni::SplitFontFallback(typography_, primary, run.text);
    for (const rni::FontSegment& seg : segs) {
      rni::ApplySegmentFamily(style, primary, seg, segs.size() == 1);
      ImpellerParagraphBuilderPushStyle(pb, style);
      ImpellerParagraphBuilderAddText(pb, (const uint8_t*)seg.text.c_str(), seg.text.size());
      ImpellerParagraphBuilderPopStyle(pb);
    }
    ImpellerParagraphStyleRelease(style);
  }
  ImpellerParagraph paragraph =
      ImpellerParagraphBuilderBuildParagraphNew(pb, w > 0 ? w : 1e6f);
  ImpellerParagraphBuilderRelease(pb);
  for (ImpellerPaint p : runPaints) ImpellerPaintRelease(p);
  return paragraph;
}

// SC-15: one silhouette paragraph per distinct textShadow among the runs, drawn
// under the real glyphs through the same tinted/blurred layer as content shadows.
void SceneGraph::paintTextShadows(ImpellerDisplayListBuilder builder, const SceneNode& node, float w,
                                  float px, float py) {
  std::vector<size_t> done;
  for (size_t i = 0; i < node.runs.size(); ++i) {
    const TextRun& r = node.runs[i];
    if (!r.hasShadow || r.text.empty()) continue;
    bool seen = false;
    for (size_t d : done) seen = seen || SameShadow(node.runs[d], r);
    if (seen) continue;
    done.push_back(i);
    ImpellerParagraph sp = buildRunParagraph(node, w, (int)i);
    if (sp == nullptr) continue;
    rni::ShadowSpec spec;
    spec.offsetX = r.shadowOffX;
    spec.offsetY = r.shadowOffY;
    spec.sigma = r.shadowSigma;
    std::copy(r.shadowColor, r.shadowColor + 3, spec.color);
    spec.color[3] = r.shadowColor[3] * OwnAlpha(node) * r.opacity;
    rni::BeginContentShadow(builder, spec);
    ImpellerPoint at = {px, py};
    ImpellerDisplayListBuilderDrawParagraph(builder, sp, &at);
    rni::EndContentShadow(builder);
    ImpellerParagraphRelease(sp);
  }
}

// B11: RCTViewComponentView gives the layer a shadowPath only over a
// background; without one CoreAnimation casts the shadow from the content.
static bool HasVisibleBackground(const SceneNode& n) {
  return (n.hasBackgroundColor && n.bg[3] > 0.0f) || !n.bgLayers.empty();
}

// A1 drop-shadow() and B11: each shadow repaints the subtree as a tinted,
// blurred, offset silhouette under the real paint. painted_ counts it once.
void SceneGraph::paintContentShadows(ImpellerDisplayListBuilder builder, const SceneNode& node,
                                     float originX, float originY) {
  std::vector<ShadowSpec> specs;
  if (node.hasLayerShadow && !HasVisibleBackground(node)) specs.push_back(node.layerShadow);
  specs.insert(specs.end(), node.dropShadows.begin(), node.dropShadows.end());
  for (const auto& s : specs) {
    rni::BeginContentShadow(builder, s);
    const SceneNode* prev = shadowPassNode_;
    const int counted = painted_;
    shadowPassNode_ = &node;
    paintNode(builder, node, originX, originY);
    shadowPassNode_ = prev;
    painted_ = counted;
    rni::EndContentShadow(builder);
  }
}

void SceneGraph::paintNode(ImpellerDisplayListBuilder builder,
                           const SceneNode& node, float originX,
                           float originY) {
  const auto& frame = node.layoutMetrics.frame;
  const float x = originX + (float)frame.origin.x;
  const float y = originY + (float)frame.origin.y;
  const float w = (float)frame.size.width;
  const float h = (float)frame.size.height;

  ++painted_;

  // ⛔ A DEFINITION SUBTREE PAINTS NOTHING -- AND NEITHER DO ITS CHILDREN.
  //
  // This return is BEFORE the child walk on purpose. <Defs> and <Symbol> hold
  // ordinary <Path> nodes that are perfectly paintable, so recursing would draw
  // the definition at its own coordinates: measured green ink at the symbol's
  // own (140,20) with the <Use> site left blank (fixtures/p9-usesym).
  //
  // Note this is NOT the same as skipping an unregistered component. An
  // unregistered <Symbol> arrives as plain ViewProps, mounts, and its children
  // still paint -- which is why registering Symbol WITHOUT this early return
  // would have changed nothing about the bug.
  if (node.isSvgDefinition) return;
#if RNI_SUPERSAMPLE_GL
  // ENG item 2 — SUPERSAMPLE HOOK. An <Svg> root subtree, when supersampling is
  // enabled AND a render context is wired, is rendered into an N x offscreen and
  // composited back with a linear downsample instead of painted in place. N=1
  // is a legitimate value (offscreen round-trip, no AA) — it is the mutant
  // control the gate proves does NOT anti-alias. A failure inside the helper
  // returns false and we fall through to the in-place walk below, so a broken
  // offscreen degrades to a correct-but-aliased icon, never a blank one.
  if (node.isSvgRoot && supersample_ >= 1 && renderContext_ != nullptr) {
    if (paintSvgRootSupersampled(builder, node, x, y, w, h)) {
      // ⛔ COUNT THE SUBTREE CACHE-INDEPENDENTLY. The offscreen render (which is
      // the only thing that walks the children, and only on a cache MISS) does
      // NOT touch painted_ — so painted_nodes must be attributed here, the same
      // whether the texture was rendered or fetched from svgCache_. The OUTER
      // ++painted_ above already counted this root once; add the rest of the
      // subtree exactly as an in-place walk would have. This makes painted_
      // depend only on the scene graph, never on cache state.
      painted_ += countPaintedNodes(node, svgUseDepth_) - 1;
      return;
    }
  }
  // <world> ENG-09. Same shape as the SVG supersample hook just above: a
  // dedicated node kind short-circuits the ordinary paint (background/
  // border/text/children) walk. Gated on renderContext_ for the SAME reason
  // the SVG hook is -- glTexImage2D/ImpellerTextureCreateWithOpenGLTextureHandleNew
  // need the surface's GL sharegroup, so a host that never wired a render
  // context (or a <world> whose store has nothing published yet) falls
  // through to the plain in-place walk below, which paints this leaf's
  // background/border and nothing else -- never a crash, never a blank
  // surprise beyond "no image".
  if (node.isWorldRaster && renderContext_ != nullptr) {
    if (paintWorldNode(builder, node, x, y, w, h)) {
      // ENG-10: the drawSprites list composites OVER the world buffer, on the
      // GPU, inside this same single <world> node (no per-sprite nodes).
      paintWorldSprites(builder, node, x, y, w, h);
      return;
    }
  }
#endif
  // backfaceVisibility 'hidden': a node whose plane faces away paints nothing,
  // children included (they share its transformed plane).
  if (node.backfaceHidden) return;
  ImpellerPaint paint = ImpellerPaintNew();
  ImpellerRect rect = {x, y, w, h};  // {x,y,w,h}, NOT LTRB

  // TRANSFORM. Pushed as translate(origin) * M * translate(-origin) so the
  // matrix RN resolved (which is expressed about the node's own box) applies at
  // the node's painted position. Everything the node draws — background,
  // borders, text, children — is inside this save, because a transform that
  // moved only the background would be a subtler wrong than no transform.
  // A1/B11: a content-shadow pass of this node runs inside its own layers, already open.
  const bool shadowPass = shadowPassNode_ == &node;
  const bool transformed = node.hasTransform && !shadowPass;
  if (transformed) {
    ImpellerDisplayListBuilderSave(builder);
    // ImpellerMatrix is column-major float[16], the same layout RN uses, so the
    // matrix copies straight across with no transposition.
    ImpellerMatrix pre = {{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0,
                           x + w * 0.5f, y + h * 0.5f, 0, 1}};
    ImpellerMatrix m{};
    for (int i = 0; i < 16; ++i) m.m[i] = (float)node.transform[i];
    ImpellerMatrix post = {{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0,
                            -(x + w * 0.5f), -(y + h * 0.5f), 0, 1}};
    ImpellerDisplayListBuilderTransform(builder, &pre);
    ImpellerDisplayListBuilderTransform(builder, &m);
    ImpellerDisplayListBuilderTransform(builder, &post);
  }

  // parity item 8: group opacity (see UsesOpacityLayer). Opened AFTER the
  // transform so the layer is in the node's transformed space, and closed
  // just before the transform restore at the end of paintNode. The bounds are
  // a hint only (children may overflow the frame, so it is not the frame);
  // Impeller sizes the offscreen from the content's actual coverage.
  // A2: mixBlendMode composites this node's whole group onto the backdrop;
  // isolation:isolate opens the same transparent group with a plain composite.
  // Opacity and filter layers are groups already.
  const bool blendLayer = !shadowPass && (node.mixBlend != react::BlendMode::Normal || node.isolate);
  if (blendLayer) rni::BeginBlendGroup(builder, rni::ToImpellerBlend(node.mixBlend));
  const bool opacityLayer = UsesOpacityLayer(node) && !shadowPass;
  if (opacityLayer) {
    ImpellerPaint layerPaint = ImpellerPaintNew();
    const ImpellerColor lc = {1.0f, 1.0f, 1.0f,
                              std::clamp(node.opacity, 0.0f, 1.0f),
                              kImpellerColorSpaceSRGB};
    ImpellerPaintSetColor(layerPaint, &lc);
    const ImpellerRect layerBounds = {-100000.0f, -100000.0f, 200000.0f,
                                      200000.0f};
    ImpellerDisplayListBuilderSaveLayer(builder, &layerBounds, layerPaint,
                                        nullptr);
    ImpellerPaintRelease(layerPaint);
  }

  // CSS filter colour matrix: a layer inside the opacity layer (filter, then opacity).
  // blur() rides the same layer as an image filter, so it blurs drop-shadows too.
  const bool filterLayer = (node.hasFilterMatrix || node.blurSigma > 0.0f) && !shadowPass;
  if (filterLayer) {
    ImpellerPaint fp = ImpellerPaintNew();
    if (node.hasFilterMatrix) {
      ImpellerColorFilter cf = rni::MakeMatrixColorFilter(node.filterMatrix);
      ImpellerPaintSetColorFilter(fp, cf);
      ImpellerColorFilterRelease(cf);
    }
    if (ImpellerImageFilter bf = rni::MakeBlurImageFilter(node.blurSigma)) {
      ImpellerPaintSetImageFilter(fp, bf);
      ImpellerImageFilterRelease(bf);
    }
    const ImpellerRect fb = {-100000.0f, -100000.0f, 200000.0f, 200000.0f};
    ImpellerDisplayListBuilderSaveLayer(builder, &fb, fp, nullptr);
    ImpellerPaintRelease(fp);
  }
  if (!shadowPass) paintContentShadows(builder, node, originX, originY);

  // ⛔ THE SVG MATRIX MUST WRAP THIS NODE *AND ITS CHILDREN*.
  //
  // <G transform> means "transform everything inside me" -- a group paints no
  // ink of its own, so applying the matrix only around this node's own draw
  // calls would be indistinguishable from dropping it entirely. The matching
  // restore therefore sits after the child walk, next to the `transformed`
  // one, NOT at the end of this node's own painting.
  //
  // Six floats, column-major 2D affine [a, b, c, d, tx, ty], expanded into
  // Impeller's column-major 4x4:
  //
  //     | a  c  0  tx |          m[0]=a  m[4]=c  m[8]=0   m[12]=tx
  //     | b  d  0  ty |    ->    m[1]=b  m[5]=d  m[9]=0   m[13]=ty
  //     | 0  0  1  0  |          m[2]=0  m[6]=0  m[10]=1  m[14]=0
  //     | 0  0  0  1  |          m[3]=0  m[7]=0  m[11]=0  m[15]=1
  //
  // Getting b and c the wrong way round transposes every rotation and skew
  // while leaving translate and uniform scale looking perfect -- which is why
  // the gate probes a scale, not just a translation.
  const bool svgTransformed = node.hasSvgMatrix;
  if (svgTransformed) {
    const float a = node.svgMatrix[0], b = node.svgMatrix[1];
    const float c = node.svgMatrix[2], d = node.svgMatrix[3];
    const float tx = node.svgMatrix[4], ty = node.svgMatrix[5];
    ImpellerMatrix sm = {{a, b, 0, 0,
                          c, d, 0, 0,
                          0, 0, 1, 0,
                          tx, ty, 0, 1}};
    ImpellerDisplayListBuilderSave(builder);
    ImpellerDisplayListBuilderTransform(builder, &sm);
  }
  // ⛔ THE ROOT <Svg> viewBox MAPPING. ENG-05a.
  //
  // Wraps this node AND its subtree, so the save is here and the restore sits
  // next to the svgTransformed one after the child walk. A mapping applied only
  // around the root's own draws would be a no-op, because the root paints no
  // ink of its own -- every path is a descendant.
  //
  // ⛔ THIS IS A UNIFORM SCALE, NOT w/vbW BY h/vbH.
  //
  // SVG's default preserveAspectRatio is "xMidYMid meet": scale by
  // min(w/vbW, h/vbH) and CENTRE the leftover slack. Independent per-axis
  // scaling is only correct for align="none". The two agree exactly when the
  // aspect ratios match -- and every icon in the design system is a square 16
  // or 20 box over a square 24 viewBox, so a per-axis stretch passes every
  // square fixture and silently distorts the first non-square SVG anyone
  // authors. That is why the acceptance probe needs a 32x16-over-24 arm; a
  // square-only probe cannot tell the two implementations apart.
  const bool svgRootMapped = node.isSvgRoot && node.svgRootHasViewBox;
  if (svgRootMapped) {
    const float vbX = node.svgRootViewBox[0];
    const float vbY = node.svgRootViewBox[1];
    const float vbW = node.svgRootViewBox[2];
    const float vbH = node.svgRootViewBox[3];
    const float sxRaw = w / vbW;
    const float syRaw = h / vbH;

    // align="none" is the ONLY value that means "stretch". Empty means the prop
    // was never set, which SVG defines as xMidYMid meet -- not none.
    const bool noneAlign = node.svgRootAlign == "none";
    // meetOrSlice: 0 = meet (fit inside, letterbox), 1 = slice (fill, overflow).
    const bool slice = node.svgRootMeetOrSlice == 1;
    float sx = sxRaw, sy = syRaw;
    if (!noneAlign) {
      const float s = slice ? std::max(sxRaw, syRaw) : std::min(sxRaw, syRaw);
      sx = s;
      sy = s;
    }

    // Slack is what the uniform scale left over on each axis; align says who
    // gets it. xMin/yMin keep it all at the far edge, xMax/yMax at the near
    // edge, xMid/yMid (the default) split it. Under "slice" the slack is
    // NEGATIVE -- the drawing is larger than the box -- and the identical
    // arithmetic centres the overflow, which is what slice means.
    const float slackX = w - vbW * sx;
    const float slackY = h - vbH * sy;
    float offX = 0.0f, offY = 0.0f;
    if (!noneAlign) {
      const auto& a = node.svgRootAlign;
      // Substring tests rather than an exact match on all nine tokens: the X
      // and Y halves are independent and rnsvg ships them concatenated.
      if (a.find("xMax") != std::string::npos) {
        offX = slackX;
      } else if (a.find("xMin") == std::string::npos) {
        offX = slackX * 0.5f;  // xMid, and the unset default
      }
      if (a.find("YMax") != std::string::npos) {
        offY = slackY;
      } else if (a.find("YMin") == std::string::npos) {
        offY = slackY * 0.5f;  // YMid, and the unset default
      }
    }

    // A path's `d` coordinate u is painted at absolute (x + u): the path
    // painter translates by the node's origin before drawing, and every RNSVG
    // child's layout frame origin is 0 because rnsvg lays out in SVG user
    // space. So the map from a painted point q back through user space is
    //     q' = x + off + (q - x - vbMin) * s
    // which folds into a plain scale-and-translate.
    const float tx = x + offX - sx * (x + vbX);
    const float ty = y + offY - sy * (y + vbY);
    ImpellerMatrix vbm = {{sx, 0, 0, 0,
                           0, sy, 0, 0,
                           0, 0, 1, 0,
                           tx, ty, 0, 1}};
    ImpellerDisplayListBuilderSave(builder);
    // ⚠️ CLIP BEFORE THE TRANSFORM, in the node's own painted space. Under
    // "slice" the scaled drawing is deliberately larger than the viewport and
    // MUST be cut to it; without this the overflow paints over sibling UI and
    // reads as a z-order bug. Under "meet" the drawing fits and the clip is
    // harmless, so it is unconditional rather than gated on the mode.
    ImpellerRect vbClip = {x, y, w, h};
    ImpellerDisplayListBuilderClipRect(builder, &vbClip,
                                       kImpellerClipOperationIntersect);
    ImpellerDisplayListBuilderTransform(builder, &vbm);
  }


  ImpellerRoundingRadii radii = {};
  // Field order is TL, BL, TR, BR — not clockwise. node.borderRadii is stored
  // in that same order so the two cannot drift.
  radii.top_left = {node.borderRadii[0], node.borderRadiiV[0]};
  radii.bottom_left = {node.borderRadii[1], node.borderRadiiV[1]};
  radii.top_right = {node.borderRadii[2], node.borderRadiiV[2]};
  radii.bottom_right = {node.borderRadii[3], node.borderRadiiV[3]};
  const bool rounded = node.borderRadii[0] > 0.0f || node.borderRadii[1] > 0.0f ||
                       node.borderRadii[2] > 0.0f || node.borderRadii[3] > 0.0f;

  // A7: continuous corners fill and clip as the squircle path; borders stay circular.
  const bool continuous = rounded && node.borderContinuous;
  auto drawBoxWith = [&](ImpellerPaint p) {
    ImpellerPath sq = rni::MakeContinuousRRectPath(x, y, w, h, radii);
    if (sq == nullptr) return false;
    ImpellerDisplayListBuilderDrawPath(builder, sq, p);
    ImpellerPathRelease(sq);
    return true;
  };
  auto fillBox = [&]() {
    if (continuous && drawBoxWith(paint)) return;
    if (rounded) {
      ImpellerDisplayListBuilderDrawRoundedRect(builder, &rect, &radii, paint);
    } else {
      ImpellerDisplayListBuilderDrawRect(builder, &rect, paint);
    }
  };

  // SHADOWS (style audit items 1-4), BEHIND the box: elevation's material
  // shadow, then the iOS shadow and outer boxShadows. They paint before the
  // background so the box covers its own umbra.
  ShadowBox shadowBox{x, y, w, h, radii, rounded};
  if (node.elevation > 0.0f) {
    PaintElevationShadow(builder, shadowBox, node.elevation, node.elevationColor,
                         OwnAlpha(node), pointScale_);
  }
  if (node.hasLayerShadow && HasVisibleBackground(node)) {
    PaintOuterShadows(builder, shadowBox, {node.layerShadow}, OwnAlpha(node));
  }
  if (!node.shadows.empty()) {
    PaintOuterShadows(builder, shadowBox, node.shadows, OwnAlpha(node));
  }

  // CSS order: background colour first, then every image layer over it.
  if (node.hasBackgroundColor && node.bg[3] > 0.0f) {
    ImpellerColor c = impellerColor(node.bg, OwnAlpha(node));
    ImpellerPaintSetColor(paint, &c);
    fillBox();
  }
  if (!node.bgLayers.empty()) {
    PaintBackgroundLayers(builder, node.bgLayers, x, y, OwnAlpha(node), [&](ImpellerPaint gp) {
      if (continuous && drawBoxWith(gp)) return;
      if (rounded) {
        ImpellerDisplayListBuilderDrawRoundedRect(builder, &rect, &radii, gp);
      } else {
        ImpellerDisplayListBuilderDrawRect(builder, &rect, gp);
      }
    });
  }

  // Inset boxShadows sit over the background and under the border (CSS).
  if (!node.shadows.empty()) {
    PaintInsetShadows(builder, shadowBox, node.borderWidths, node.shadows,
                      OwnAlpha(node));
  }

  paintBorders(builder, node, x, y, w, h, radii, rounded);
  if (node.outlineWidth > 0.0f) {
    rni::PaintOutline(builder, x, y, w, h, radii, node.outlineWidth, node.outlineOffset,
                      node.outlineStyle, impellerColor(node.outlineColor, OwnAlpha(node)));
  }

#if RNI_SUPERSAMPLE_GL
  // ENG-10: a <world> with a sprite list but NO setPixels buffer still
  // composites its sprites, over its own background painted just above. (With
  // a buffer, the early return in the <world> hook already drew them.)
  if (node.isWorldRaster && renderContext_ != nullptr) {
    paintWorldSprites(builder, node, x, y, w, h);
  }
#endif

  // item 11: keyboard focus ring on the focused (non-TextInput) View: a 2pt
  // outline just outside the frame, macOS/Windows focus blue.
  if (focusedView_ != 0 && focusedView_ == node.tag) {
    ImpellerPaint ring = ImpellerPaintNew();
    const ImpellerColor rc = {0.0f, 0.4039f, 0.9569f, 1.0f, kImpellerColorSpaceSRGB};
    ImpellerPaintSetColor(ring, &rc);
    ImpellerPaintSetDrawStyle(ring, kImpellerDrawStyleStroke);
    ImpellerPaintSetStrokeWidth(ring, 2.0f);
    const ImpellerRect rr = {x - 2.0f, y - 2.0f, w + 4.0f, h + 4.0f};
    ImpellerDisplayListBuilderDrawRect(builder, &rr, ring);
    ImpellerPaintRelease(ring);
  }

#if RNI_WITH_RNSVG
  // RNSVGPath: parse `d` fresh into an ImpellerPathBuilder every paint (no
  // cross-frame geometry cache exists in this SceneGraph, unlike gradients/
  // borders which are pure ImpellerColor/Rect values) and fill it.
  //
  // ⛔ EFFECTIVE ALPHA IS clamp(fillOpacity) * clamp(opacity), PER PATH. This
  // is the HostApp mark's product requirement (17 paths, grey ramp IS the
  // per-path fillOpacity), not a rounding nicety — do not fold it into a
  // single shared paint the way plain Views share `paint` above.
  // ⛔ THE GUARD IS fill-OR-stroke, NOT fill.
  //
  // An SVG element may have a stroke and NO fill -- an outlined shape is
  // ordinary in real artwork. Gating the whole block on svgHasFill would make
  // every stroke-only element paint nothing, silently, which is the same class
  // of failure as the dropped brush that shipped in P9-B2.
  // ⛔ THE GUARD MUST INCLUDE REFERENCE BRUSHES.
  //
  // svgHasFill/svgHasStroke mean "resolved to a literal colour", and a
  // url(#id) brush resolves to NEITHER -- it is a reference looked up at paint
  // time. Testing only the colour flags skips the whole block for every
  // gradient-filled shape: parsed correctly, registry built correctly, and
  // nothing drawn. Exactly the silent shape this phase keeps producing.
  if (node.isSvgPath &&
      (node.svgHasFill || node.svgHasStroke || node.svgFillIsRef ||
       node.svgStrokeIsRef) &&
      !node.svgD.empty()) {
    ImpellerPathBuilder pb = ImpellerPathBuilderNew();
    if (pb != nullptr) {
      if (ParseSvgPathToBuilder(node.svgD, pb)) {
        const ImpellerFillType fillType = node.svgFillEvenOdd
                                               ? kImpellerFillTypeOdd
                                               : kImpellerFillTypeNonZero;
        ImpellerPath path = ImpellerPathBuilderTakePathNew(pb, fillType);
        if (path != nullptr) {
          const float nodeAlpha = std::clamp(OwnAlpha(node), 0.0f, 1.0f);
          const float fillAlpha =
              std::clamp(node.svgFillOpacity, 0.0f, 1.0f) * nodeAlpha;
          const float strokeAlpha =
              std::clamp(node.svgStrokeOpacity, 0.0f, 1.0f) * nodeAlpha;

          // The `d` coordinates are in the SVG's own local space; translate
          // once so both passes land at the node's painted origin.
          ImpellerDisplayListBuilderSave(builder);
          ImpellerDisplayListBuilderTranslate(builder, x, y);

          if (node.svgHasFill && fillAlpha > 0.0f) {
            ImpellerColor fc = impellerColor(node.svgFillColor, fillAlpha);
            ImpellerPaint svgPaint = ImpellerPaintNew();
            ImpellerPaintSetColor(svgPaint, &fc);
            ImpellerDisplayListBuilderDrawPath(builder, path, svgPaint);
            ImpellerPaintRelease(svgPaint);
          } else if (node.svgFillIsRef && fillAlpha > 0.0f) {
            // fill="url(#id)" — resolve against the gradient registry built
            // from the def nodes. A miss paints NOTHING rather than a guessed
            // colour: a wrong colour is a bug that looks like a design choice.
            auto git = gradients_.find(node.svgFillRef);
            if (git != gradients_.end()) {
              // ⛔ objectBoundingBox UNITS MEAN THE SHAPE'S BOX, NOT THE NODE'S
              // LAYOUT FRAME.
              //
              // Every RNSVG node's layout frame is the whole SVG surface
              // (measured: `node_frame=RNSVGRect,8,0,0,400,300` for a 200x80
              // rect), because rnsvg does its own layout in SVG user space.
              // Using the frame stretched every gradient across the entire
              // canvas -- the ramp still rendered, just badly wrong: a
              // red->blue gradient reached only (118,0,137) at the shape's
              // right edge instead of pure blue, and a white-centred radial
              // read (66,66,66) at its centre. Ask the PATH for its bounds.
              ImpellerRect b = {0, 0, 0, 0};
              ImpellerPathGetBounds(path, &b);
              ImpellerColorSource src = makeGradientSource(
                  git->second, b.x, b.y, b.width, b.height, fillAlpha);
              if (src != nullptr) {
                // ⛔ Its OWN paint. ImpellerPaintSetColorSource is declared
                // IMPELLER_NONNULL, so a colour source can never be CLEARED
                // once set — a shared paint would gradient-fill everything
                // drawn after it. Same trap the View gradient path documents.
                ImpellerPaint gp = ImpellerPaintNew();
                ImpellerPaintSetColorSource(gp, src);
                ImpellerDisplayListBuilderDrawPath(builder, path, gp);
                ImpellerPaintRelease(gp);
                ImpellerColorSourceRelease(src);
              }
            }
          }

          // ⛔ STROKE IS A SECOND DRAW, NOT kImpellerDrawStyleStrokeAndFill.
          //
          // SVG gives fill and stroke INDEPENDENT colours and opacities, and a
          // single paint carries only one colour. StrokeAndFill would force
          // the stroke to be the fill's colour -- which looks plausible on a
          // shape whose fill and stroke happen to match and is wrong
          // everywhere else. Draw order is fill-then-stroke, as SVG specifies.
          if (node.svgHasStroke && strokeAlpha > 0.0f &&
              node.svgStrokeWidth > 0.0f) {
            ImpellerColor sc = impellerColor(node.svgStrokeColor, strokeAlpha);
            ImpellerPaint strokePaint = ImpellerPaintNew();
            ImpellerPaintSetColor(strokePaint, &sc);
            ImpellerPaintSetDrawStyle(strokePaint, kImpellerDrawStyleStroke);
            ImpellerPaintSetStrokeWidth(strokePaint, node.svgStrokeWidth);
            // rnsvg encodes cap/join as ints in SVG's own order.
            ImpellerPaintSetStrokeCap(
                strokePaint, node.svgStrokeLinecap == 1 ? kImpellerStrokeCapRound
                             : node.svgStrokeLinecap == 2
                                 ? kImpellerStrokeCapSquare
                                 : kImpellerStrokeCapButt);
            ImpellerPaintSetStrokeJoin(
                strokePaint, node.svgStrokeLinejoin == 1
                                 ? kImpellerStrokeJoinRound
                             : node.svgStrokeLinejoin == 2
                                 ? kImpellerStrokeJoinBevel
                                 : kImpellerStrokeJoinMiter);
            ImpellerPaintSetStrokeMiter(strokePaint, node.svgStrokeMiterlimit);
            // ENG-13: a dashed stroke strokes the DASHED path (cut from the
            // same `d` parse), and the fill above keeps the whole shape. A
            // path that cannot be dashed (too many dashes) strokes solid.
            ImpellerPath dashed = nullptr;
            if (!node.svgStrokeDash.empty()) {
              dashed = BuildDashedSvgPath(node.svgD, node.svgStrokeDash,
                                          node.svgStrokeDashOffset,
                                          node.svgStrokeLinecap != 0);  // ENG-13 capDots
            }
            ImpellerDisplayListBuilderDrawPath(
                builder, dashed != nullptr ? dashed : path, strokePaint);
            if (dashed != nullptr) ImpellerPathRelease(dashed);
            ImpellerPaintRelease(strokePaint);
          }

          ImpellerDisplayListBuilderRestore(builder);
          ImpellerPathRelease(path);
        }
      }
      ImpellerPathBuilderRelease(pb);
    }
  }
#endif

  if (node.isParagraph && !node.runs.empty() && typography_ != nullptr) {
    // B1: glyphs live in the content box (border + padding), not the frame.
    const auto& pins = node.layoutMetrics.contentInsets;
    const float px = x + (float)pins.left, py = y + (float)pins.top;
    ImpellerParagraph paragraph =
        buildRunParagraph(node, std::max(0.0f, w - (float)(pins.left + pins.right)));
    if (paragraph != nullptr) {
      const float vOff =
          ParagraphVOffset(node, paragraph, h - (float)(pins.top + pins.bottom));
      // P1 item 15: a selectable paragraph's selection highlight, UNDER the
      // glyphs (drawn first), one rect per selected grapheme cluster as laid
      // out in THIS paragraph, so a wrapped selection follows its lines.
      if (node.selectable && textSelTag_ == node.tag &&
          textSelAnchor_ != textSelCaret_) {
        const std::string shown = JoinRuns(node);
        const size_t lo8 = std::min(textSelAnchor_, textSelCaret_);
        const size_t hi8 = std::min(std::max(textSelAnchor_, textSelCaret_),
                                    shown.size());
        const size_t lo16 = Utf8ToUtf16Index(shown, lo8);
        const size_t hi16 = Utf8ToUtf16Index(shown, hi8);
        ImpellerPaint selPaint = ImpellerPaintNew();
        ImpellerColor sc = impellerColor(node.tiSelectionColor, OwnAlpha(node));
        ImpellerPaintSetColor(selPaint, &sc);
        for (size_t i = lo16; i < hi16;) {
          ImpellerGlyphInfo gi =
              ImpellerParagraphCreateGlyphInfoAtCodeUnitIndexNew(paragraph, i);
          if (gi == nullptr) break;
          const ImpellerRect r = ClusterBounds(gi);
          const size_t end = ImpellerGlyphInfoGetGraphemeClusterCodeUnitRangeEnd(gi);
          ImpellerGlyphInfoRelease(gi);
          ImpellerRect at = {px + r.x, py + vOff + r.y, r.width, r.height};
          ImpellerDisplayListBuilderDrawRect(builder, &at, selPaint);
          i = end > i ? end : i + 1;
        }
        ImpellerPaintRelease(selPaint);
      }
      paintTextShadows(builder, node, std::max(0.0f, w - (float)(pins.left + pins.right)), px,
                       py + vOff);
      ImpellerPoint at = {px, py + vOff};
      ImpellerDisplayListBuilderDrawParagraph(builder, paragraph, &at);
      ImpellerParagraphRelease(paragraph);
    }
  }

  // <Switch>. ENG-15. iOS UISwitch geometry, scaled to the node's frame
  // (51 x 31 by default, see fabric/SwitchShadowNode.h): a pill track filled
  // with the ON or OFF colour, and a thumb inset 2 pt, at the right end when ON
  // and the left end when OFF. A disabled switch is the whole control at half
  // opacity as a GROUP (UIKit's alpha = 0.5): track and thumb are drawn
  // opaque into a save-layer composited at 0.5, so the thumb does not show
  // the track through it.
  if (node.isSwitch && w > 0.0f && h > 0.0f) {
    const float a = OwnAlpha(node);
    if (node.swDisabled) {
      ImpellerPaint lp = ImpellerPaintNew();
      const ImpellerColor lc = {1.0f, 1.0f, 1.0f, 0.5f, kImpellerColorSpaceSRGB};
      ImpellerPaintSetColor(lp, &lc);
      const ImpellerRect lb = {x - 1.0f, y - 1.0f, w + 2.0f, h + 2.0f};
      ImpellerDisplayListBuilderSaveLayer(builder, &lb, lp, nullptr);
      ImpellerPaintRelease(lp);
    }
    ImpellerPaint sp = ImpellerPaintNew();
    ImpellerColor tc = impellerColor(node.swValue ? node.swOnColor : node.swOffColor, a);
    ImpellerPaintSetColor(sp, &tc);
    const float r = h * 0.5f;
    ImpellerRoundingRadii tr = {};
    tr.top_left = tr.bottom_left = tr.top_right = tr.bottom_right = {r, r};
    ImpellerRect track = {x, y, w, h};
    ImpellerDisplayListBuilderDrawRoundedRect(builder, &track, &tr, sp);
    const float inset = 2.0f;
    const float d = h - 2.0f * inset;
    const float tx = node.swValue ? x + w - inset - d : x + inset;
    ImpellerColor thc = impellerColor(node.swThumbColor, a);
    ImpellerPaintSetColor(sp, &thc);
    ImpellerRect thumb = {tx, y + inset, d, d};
    ImpellerDisplayListBuilderDrawOval(builder, &thumb, sp);
    ImpellerPaintRelease(sp);
    if (node.swDisabled) ImpellerDisplayListBuilderRestore(builder);
  }

  // <TextInput>. ENG-01b. Paint the field's text (the live edit buffer if this
  // field is focused, else its controlled value), or the placeholder when the
  // field is empty, plus a caret when focused. Uses the SAME Impeller paragraph
  // path as <Text> so metrics match; a single line, no wrapping constraint.
  if (node.isTextInput && typography_ != nullptr) {
    const bool focused = (tiFocused_ == node.tag);
    const std::string rawShown = focused ? tiEditValue_ : node.tiValue;
    // Style audit item 11: a secure field paints bullets, never the value.
    // `shown` is what every measurement below uses, so selection and caret
    // offsets are taken in the MASKED string (mapped by SecureMaskOffset).
    const std::string shown = node.tiSecure ? SecureMask(rawShown) : rawShown;
    const std::string editShown =
        node.tiSecure ? SecureMask(tiEditValue_) : tiEditValue_;
    auto toShown = [&](size_t n) -> size_t {
      return node.tiSecure ? SecureMaskOffset(tiEditValue_, n) : n;
    };
    const bool showPlaceholder = shown.empty() && !node.tiPlaceholder.empty();
    const std::string& drawStr = showPlaceholder ? node.tiPlaceholder : shown;
    // ENG-16: where the first line sits. Single-line fields centre it (the
    // pre-ENG-16 rule, unchanged); multiline fields default to the TOP of the
    // content box, and textAlignVertical overrides either.
    const float lineH = TextInputLineH(node);  // ENG-23 TextInput
    // ENG-25: the same helper the multiline hit test uses (TiGeomOf).
    const float ty = TextInputTextTop(typography_, node, y, w, h, drawStr);
    const auto& insets = node.layoutMetrics.contentInsets;
    // A small left inset so the glyphs (and caret) do not sit on the border.
    // Shared with glyphBoundariesLocked (item 3 click-to-caret): a click and
    // the painted text must agree on where the text starts.
    const float pad = TextInputPadL(node) + TextInputAlignDx(typography_, node, drawStr, w);
    const float padR = TextInputPadR(node);
    // ENG-24: a single-line field lays its text out on ONE line (it used to
    // wrap at the box and spill below it) and scrolls sideways to keep the
    // caret in view; a multiline field wraps inside the box and scrolls
    // vertically (wrap width: BuildTextInputParagraph, shared with the hit
    // test). The scroll is kept for the focused field (tiScrollX_/Y_)
    // and only moves when the caret would leave the box. Glyphs, selection
    // and caret are clipped to the field's box.
    float caretX = x + pad;  // unscrolled field coordinates
    float caretY = ty;
    float caretH = lineH;
    float scrollX = 0.0f, scrollY = 0.0f;
    ImpellerDisplayListBuilderSave(builder);
    {
      ImpellerRect box = {x, y, w, h};
      ImpellerDisplayListBuilderClipRect(builder, &box,
                                         kImpellerClipOperationIntersect);
    }
    if (!drawStr.empty()) {
      ImpellerParagraphStyle style = ImpellerParagraphStyleNew();
      ImpellerParagraphStyleSetFontSize(style, node.fontSize);
      ApplyFontFamily(style, node.fontFamily);  // ENG-22
      rni::ApplyTextInputFace(style, node.tiFace, false);  // SC-20: advances for prefixW
      const std::string editMeasured = rni::applyTextTransform(editShown, node.tiFace.transform);
      ImpellerPaint tPaint = ImpellerPaintNew();
      const float* col = showPlaceholder ? node.tiPlaceholderColor : node.textColor;
      ImpellerColor tc = impellerColor(col, OwnAlpha(node));
      ImpellerPaintSetColor(tPaint, &tc);
      ImpellerParagraphStyleSetForeground(style, tPaint);
      // ENG-25: built by the SAME helper the multiline hit test uses.
      ImpellerParagraph paragraph =
          BuildTextInputParagraph(typography_, node, drawStr, w, tPaint);
      if (paragraph != nullptr) {
        auto prefixW = [&](size_t n) -> float {
          if (n == 0) return 0.0f;
          ImpellerParagraphBuilder sb = ImpellerParagraphBuilderNew(typography_);
          ImpellerParagraphBuilderPushStyle(sb, style);
          ImpellerParagraphBuilderAddText(sb, (const uint8_t*)editMeasured.data(), n);
          ImpellerParagraph sp = ImpellerParagraphBuilderBuildParagraphNew(sb, 1e6f);
          float wv = 0.0f;
          if (sp != nullptr) {
            wv = ImpellerParagraphGetMaxIntrinsicWidth(sp);
            ImpellerParagraphRelease(sp);
          }
          ImpellerParagraphBuilderRelease(sb);
          return wv;
        };
        // ENG-25: a MULTILINE field's caret and selection read THIS
        // paragraph's wrapped lines. Single-line fields keep the unwrapped
        // prefix measurement below, unchanged.
        const bool wrapped = node.tiMultiline && focused && !showPlaceholder;
        std::vector<TiLine> lines;
        if (wrapped) lines = TiLinesOf(paragraph, editShown, lineH);
        // item 2a: the caret is painted at its CURRENT index, not always at
        // end-of-text. Single-line: the advance of the UTF-8 prefix up to
        // tiCaret_ (the measurement typing-at-end always used). ENG-24
        // multiline: the line metrics of the laid-out paragraph, so a caret
        // after a newline or a soft wrap sits at the next line's start.
        // Placeholder text is not editable, so no caret offset is taken from
        // it. The caret decides the scroll, so it comes first.
        if (wrapped) {
          // ENG-25: the caret's wrapped line and x in the painted layout.
          const size_t m8 = toShown(tiCaret_);
          const size_t Ln = TiLineIndex(lines, Utf8ToUtf16Index(editShown, m8));
          caretX = x + pad + TiCaretX(paragraph, lines[Ln], editShown, m8);
          caretY = ty + lines[Ln].top;
          caretH = lines[Ln].height;
          // ENG-24: scroll vertically so the caret's line stays in the box.
          const float visTop = y + (float)insets.top;
          const float visBot = y + h - (float)insets.bottom;
          float sy = tiScrollY_;
          if (caretY + caretH - sy > visBot) sy = caretY + caretH - visBot;
          if (caretY - sy < visTop) sy = caretY - visTop;
          tiScrollY_ = scrollY = std::max(0.0f, sy);
        } else if (focused && !showPlaceholder) {
          caretX = x + pad + prefixW(toShown(tiCaret_));
          const float visL = x + pad;
          const float visR = x + w - padR - 1.0f;  // the 1 pt caret bar fits
          float sx = tiScrollX_;
          if (caretX - sx > visR) sx = caretX - visR;
          if (caretX - sx < visL) sx = caretX - visL;
          const float textW = ImpellerParagraphGetMaxIntrinsicWidth(paragraph);
          const float maxS = std::max(0.0f, textW - (visR - visL));
          tiScrollX_ = scrollX = std::min(std::max(0.0f, sx), maxS);
        }
        ImpellerPoint at = {x + pad - scrollX, ty - scrollY};
        // item 4a: selection highlight, BEHIND the glyphs. Single-line: the
        // x-extent uses the same prefix-width measurement as the caret, so
        // the highlight edges and the caret positions agree. ENG-24
        // multiline: one rect per selected cluster, so a selection that
        // spans lines highlights each line's own glyphs.
        if (focused && !showPlaceholder && tiSelAnchor_ != tiCaret_) {
          const size_t lo = toShown(std::min(tiSelAnchor_, tiCaret_));
          const size_t hi = toShown(std::min(std::max(tiSelAnchor_, tiCaret_),
                                             tiEditValue_.size()));
          ImpellerPaint selPaint = ImpellerPaintNew();
          ImpellerColor sc = impellerColor(node.tiSelectionColor, OwnAlpha(node));
          ImpellerPaintSetColor(selPaint, &sc);
          if (wrapped) {
            // ENG-25: one rect per wrapped line the selection touches. A
            // line whose selection runs past its end is covered to its end.
            const size_t lo16 = Utf8ToUtf16Index(editShown, lo);
            const size_t hi16 = Utf8ToUtf16Index(editShown, hi);
            const size_t len16 = Utf8ToUtf16Index(editShown, editShown.size());
            for (size_t L = 0; L < lines.size(); ++L) {
              const size_t s = lines[L].start16;
              const size_t e =
                  L + 1 < lines.size() ? lines[L + 1].start16 : len16 + 1;
              const size_t a = std::max(lo16, s);
              const size_t b = std::min(hi16, e);
              if (a >= b) continue;
              const float x0 = TiCaretX(paragraph, lines[L], editShown,
                                        Utf16ToUtf8Index(editShown, a));
              const float x1 =
                  b < e ? TiCaretX(paragraph, lines[L], editShown,
                                   Utf16ToUtf8Index(editShown, b))
                        : std::max(lines[L].left + lines[L].width,
                                   x0 + node.fontSize * 0.3f);
              ImpellerRect selRect = {at.x + x0, at.y + lines[L].top, x1 - x0,
                                      lines[L].height};
              ImpellerDisplayListBuilderDrawRect(builder, &selRect, selPaint);
            }
          } else {
            const float x0 = x + pad + prefixW(lo) - scrollX;
            const float x1 = x + pad + prefixW(hi) - scrollX;
            ImpellerRect selRect = {x0, ty, x1 - x0, lineH};
            ImpellerDisplayListBuilderDrawRect(builder, &selRect, selPaint);
          }
          ImpellerPaintRelease(selPaint);
        }
        ImpellerDisplayListBuilderDrawParagraph(builder, paragraph, &at);
        ImpellerParagraphRelease(paragraph);
      }
      ImpellerPaintRelease(tPaint);
      ImpellerParagraphStyleRelease(style);
    }
    // The caret: a 1-point-wide vertical bar at the insertion point, painted
    // only while focused AND in an ON blink phase. Drawn last so it sits over
    // the text. This is the visible proof of focus a read-only surface can
    // never show. item 5: the blink phase is a pure function of the time since
    // the last caret reset (focus/click/keystroke) -- see CaretBlink.h -- so a
    // burst of typing always re-shows it and a screenshot in an off phase is a
    // real off phase, not a missing caret.
    // item 4a: no caret while a non-empty selection is shown (macOS and
    // Windows both hide it; the highlight marks the insertion range).
    if (focused && tiSelAnchor_ == tiCaret_ && !node.tiFace.caretHidden) {
      const long long msSinceReset =
          std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now() - tiCaretResetAt_)
              .count();
      // ENG-25 gate hook: RNI_CARET_BLINK_MS=0 paints a SOLID caret, so a
      // windowed screenshot of the caret can never land in an off phase.
      // Unset = the platform half-period (kCaretBlinkPeriodMs).
      static const int kBlinkMs = [] {
        const char* e = std::getenv("RNI_CARET_BLINK_MS");
        return e != nullptr ? std::atoi(e) : kCaretBlinkPeriodMs;
      }();
      if (caretVisible(msSinceReset, kBlinkMs)) {
        ImpellerPaint caretPaint = ImpellerPaintNew();
        // SC-20: cursorColor tints the caret; without it the caret follows the text.
        ImpellerColor cc = impellerColor(
            node.tiFace.hasCursorColor ? node.tiFace.cursorColor : node.textColor, OwnAlpha(node));
        ImpellerPaintSetColor(caretPaint, &cc);
        ImpellerRect caretRect = {caretX - scrollX, caretY - scrollY, 1.0f,
                                  caretH};
        ImpellerDisplayListBuilderDrawRect(builder, &caretRect, caretPaint);
        ImpellerPaintRelease(caretPaint);
      }
    }
    ImpellerDisplayListBuilderRestore(builder);  // ENG-24 box clip
  }

  ImpellerPaintRelease(paint);

  // Children are positioned relative to this node's frame origin.
  const bool clip = node.overflowHidden;
  if (clip) {
    ImpellerDisplayListBuilderSave(builder);
    // Style audit item 13: a rounded box clips its children to the ROUNDED
    // outline (iOS masksToBounds + cornerRadius), not to its square frame.
    ImpellerPath sqClip = continuous ? rni::MakeContinuousRRectPath(x, y, w, h, radii) : nullptr;
    if (sqClip != nullptr) {
      ImpellerDisplayListBuilderClipPath(builder, sqClip, kImpellerClipOperationIntersect);
      ImpellerPathRelease(sqClip);
    } else if (rounded) {
      ImpellerDisplayListBuilderClipRoundedRect(builder, &rect, &radii,
                                                kImpellerClipOperationIntersect);
    } else {
      ImpellerDisplayListBuilderClipRect(builder, &rect,
                                         kImpellerClipOperationIntersect);
    }
  }
  // <ScrollView>. ENG-02. The offset shifts the CHILD ORIGIN, it does not move
  // this node.
  //
  // ⛔ THE CLIP IS TAKEN BEFORE THE SHIFT, ON PURPOSE. The clip rect is this
  // node's frame in the PARENT's space -- the viewport, which does not move --
  // while the content slides underneath it. Applying the shift first (or
  // translating the builder around both) would drag the clip rect along with
  // the content, so rows would scroll and the window onto them would scroll
  // too: nothing would ever appear to move, and every offset would still be
  // arithmetically correct. That is the failure mode this ordering exists to
  // prevent.
  //
  // ⚠️ Done by adjusting the child origin rather than by a builder translate so
  // it composes with the SVG/transform saves above without a fourth save/
  // restore pair to keep balanced.
  float childOriginY = y;
  float childOriginX = x;
  if (node.isScrollView) {
    childOriginY -= node.scrollY;
    childOriginX -= node.scrollX;
  }
  for (auto childTag : node.children) {
    auto it = nodes_.find(childTag);
    if (it != nodes_.end()) {
      paintNode(builder, it->second, childOriginX, childOriginY);
    }
  }

  // <Use href="#id"> -- paint the referenced definition's subtree HERE.
  //
  // This is what makes symbol+use work at all: the definition is skipped at its
  // own site (isSvgDefinition above) and re-entered from each instance, so N
  // <Use> refs to one <Symbol> produce N drawings of ONE asset. The alternative
  // -- inlining the paths at every mounting site in the source -- duplicates
  // the artwork N times and loses the single-source guarantee that makes a
  // content hash of the symbol block meaningful.
  //
  // ⚠️ A DANGLING href PAINTS NOTHING, DELIBERATELY. `url(#missing)` is a real
  // authoring state; falling back to a default fill would silently invent art.
  if (node.isSvgUse && !node.svgUseHref.empty() && svgUseDepth_ < kMaxUseDepth) {
    auto def = svgDefs_.find(node.svgUseHref);
    if (def != svgDefs_.end() && def->second != nullptr) {
      const SceneNode& target = *def->second;
      ImpellerDisplayListBuilderSave(builder);
      // Instance placement. x/y translate the instance; when BOTH width and
      // height are given AND the symbol declares a viewBox, the instance is
      // also scaled to fit -- that is the whole point of <symbol viewBox> and
      // dropping it makes every <Use> paint at the symbol's authoring size,
      // which looks like "the logo is the wrong size" rather than a bug.
      float sx = 1.0f, sy = 1.0f;
      if (node.svgUseHasSize && target.svgSymbolViewBox[2] > 0.0f &&
          target.svgSymbolViewBox[3] > 0.0f) {
        sx = node.svgUseBox[2] / target.svgSymbolViewBox[2];
        sy = node.svgUseBox[3] / target.svgSymbolViewBox[3];
      }
      const float tx = node.svgUseBox[0] - target.svgSymbolViewBox[0] * sx;
      const float ty = node.svgUseBox[1] - target.svgSymbolViewBox[1] * sy;
      ImpellerMatrix um = {{sx, 0, 0, 0,
                            0, sy, 0, 0,
                            0, 0, 1, 0,
                            tx, ty, 0, 1}};
      ImpellerDisplayListBuilderTransform(builder, &um);
      ++svgUseDepth_;
      // The TARGET's own children, not the target: the <Symbol> node itself is
      // a definition container and would bounce straight off the early return.
      for (auto defChild : target.children) {
        auto ct = nodes_.find(defChild);
        if (ct != nodes_.end()) paintNode(builder, ct->second, x, y);
      }
      --svgUseDepth_;
      ImpellerDisplayListBuilderRestore(builder);
    }
  }
  if (node.isScrollView) {
    // A21: indicators overlay the content, inside the viewport clip.
    rni::ScrollIndicatorSpec si = {x, y, w, h, 0.0f, 0.0f, node.scrollX, node.scrollY,
                                   node.showsVerticalScrollIndicator,
                                   node.showsHorizontalScrollIndicator,
                                   node.scrollIndicatorStyle};
    for (auto childTag : node.children) {
      auto content = nodes_.find(childTag);
      if (content == nodes_.end()) continue;
      const auto& cf = content->second.layoutMetrics.frame;
      si.contentW = std::max(si.contentW, (float)(cf.origin.x + cf.size.width));
      si.contentH = std::max(si.contentH, (float)(cf.origin.y + cf.size.height));
    }
    rni::PaintScrollIndicators(builder, si);
  }
  if (clip) {
    ImpellerDisplayListBuilderRestore(builder);
  }
  // Paired with the viewBox save above. AFTER the child walk, for the same
  // reason the SVG-matrix restore is: the mapping exists to transform the
  // subtree, so restoring before the walk would drop it entirely while leaving
  // the save/restore count balanced -- a silent no-op rather than a crash.
  if (svgRootMapped) {
    ImpellerDisplayListBuilderRestore(builder);
  }
  // Paired with the save above; must come AFTER the child walk so a group's
  // transform applies to its subtree.
  if (svgTransformed) {
    ImpellerDisplayListBuilderRestore(builder);
  }
  if (filterLayer) {
    ImpellerDisplayListBuilderRestore(builder);  // A1: colour-matrix filter
  }
  if (opacityLayer) {
    ImpellerDisplayListBuilderRestore(builder);  // item 8: group opacity
  }
  if (blendLayer) {
    ImpellerDisplayListBuilderRestore(builder);  // A2: blend / isolation group
  }
  if (transformed) {
    ImpellerDisplayListBuilderRestore(builder);
  }
}

// ENG item 2 — content key for the per-icon offscreen texture cache.
//
// Every input that changes the rasterised pixels must be in the key: the
// geometry (each descendant path's `d`), the colours and stroke widths, the
// resolved pixel size, and N (via pxW/pxH which already fold N in). A key that
// omitted stroke width would reuse a 1.8px chevron's texture for a 3px one;
// omitting colour would paint every icon the first colour seen at that size.
// Keyed by CONTENT, not by tag, so the same icon on 40 rows rasterises once.
std::string SceneGraph::svgSubtreeCacheKey(const SceneNode& node, int pxW,
                                           int pxH) const {
  std::string key;
  key.reserve(256);
  char buf[512];
  std::snprintf(buf, sizeof(buf), "sz=%dx%d;", pxW, pxH);
  key += buf;
  // Walk the subtree in the SAME order paint does, appending each drawable's
  // pixel-affecting props. Recursion mirrors paintNode's child loop so the key
  // cannot drift out of sync with what is actually drawn.
  std::function<void(const SceneNode&)> walk = [&](const SceneNode& n) {
    if (n.isSvgPath && !n.svgD.empty()) {
      key += "d=";
      key += n.svgD;
      std::snprintf(buf, sizeof(buf),
                    ";f=%d,%.3f,%.3f,%.3f,%.3f,%.3f;s=%d,%.3f,%.3f,%.3f,%.3f,"
                    "%.3f,%.3f;m=%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f;o=%.3f;",
                    n.svgHasFill ? 1 : 0, n.svgFillColor[0], n.svgFillColor[1],
                    n.svgFillColor[2], n.svgFillColor[3], n.svgFillOpacity,
                    n.svgHasStroke ? 1 : 0, n.svgStrokeColor[0],
                    n.svgStrokeColor[1], n.svgStrokeColor[2],
                    n.svgStrokeColor[3], n.svgStrokeOpacity, n.svgStrokeWidth,
                    n.hasSvgMatrix ? 1 : 0, n.svgMatrix[0], n.svgMatrix[1],
                    n.svgMatrix[2], n.svgMatrix[3], n.svgMatrix[4],
                    n.svgMatrix[5], n.opacity);
      key += buf;
      // ENG-13: dashes change the pixels, so they are part of the key.
      key += "dash=";
      for (float v : n.svgStrokeDash) {
        std::snprintf(buf, sizeof(buf), "%.3f,", v);
        key += buf;
      }
      std::snprintf(buf, sizeof(buf), "@%.3f,c%d;", n.svgStrokeDashOffset,
                    n.svgStrokeLinecap);
      key += buf;
    }
    for (auto childTag : n.children) {
      auto it = nodes_.find(childTag);
      if (it != nodes_.end()) walk(it->second);
    }
  };
  walk(node);
  return key;
}

#if RNI_SUPERSAMPLE_GL
// ENG item 2 — render the <Svg> subtree into a fresh pxW x pxH offscreen FBO and
// adopt its colour texture. The heavy lifting (GL FBO dance, re-entry guard,
// coordinate mapping) lives here so both the initial N x rasterise and any
// intermediate size go through one code path.
ImpellerTexture SceneGraph::renderSvgSubtreeToTexture(const SceneNode& node,
                                                      float x, float y, float w,
                                                      float h, int pxW,
                                                      int pxH) {
  GLint prevFbo = 0;
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
  GLint prevViewport[4] = {0, 0, 0, 0};
  glGetIntegerv(GL_VIEWPORT, prevViewport);

  GLuint colorTex = 0, fbo = 0, depthStencil = 0;
  glGenTextures(1, &colorTex);
  glBindTexture(GL_TEXTURE_2D, colorTex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, pxW, pxH, 0, GL_RGBA,
               GL_UNSIGNED_BYTE, nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         colorTex, 0);
  // ⛔ DEPTH+STENCIL OR EVERY CONCAVE FILL PAINTS ITS BOUNDING BOX. Impeller's
  // non-convex fills are stencil-then-cover; a colour-only offscreen FBO makes
  // the accumulate pass a no-op and the cover pass unmasked. Chevrons are
  // strokes (convex quads, would survive), but an icon set has filled concave
  // glyphs too — the exact silent-wrong-shape trap HeadlessSurface documents.
  glGenRenderbuffers(1, &depthStencil);
  glBindRenderbuffer(GL_RENDERBUFFER, depthStencil);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, pxW, pxH);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                            GL_RENDERBUFFER, depthStencil);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT,
                            GL_RENDERBUFFER, depthStencil);

  ImpellerTexture texture = nullptr;
  bool ok = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  ImpellerSurface offscreen = nullptr;
  if (ok) {
    ImpellerISize size = {pxW, pxH};
    offscreen = ImpellerSurfaceCreateWrappedFBONew(
        renderContext_, fbo, kImpellerPixelFormatRGBA8888, &size);
    ok = offscreen != nullptr;
  }
  if (ok) {
    // Map the painted box (x,y,w,h) onto the whole (0,0,pxW,pxH) offscreen.
    // Scale then translate: a point p lands at scale*(p - origin), so
    // (x,y)->(0,0) and (x+w,y+h)->(pxW,pxH). Exact ratios absorb the ceil().
    const float sx = (float)pxW / w;
    const float sy = (float)pxH / h;
    ImpellerDisplayListBuilder off = ImpellerDisplayListBuilderNew(nullptr);
    ImpellerDisplayListBuilderScale(off, sx, sy);
    ImpellerDisplayListBuilderTranslate(off, -x, -y);
    // ⛔ SUPPRESS RE-ENTRY. paintNode would otherwise take the supersample hook
    // again for this very node and recurse forever. Zero it for the inner walk,
    // restore after — nested <Svg> roots simply paint in place.
    const int savedN = supersample_;
    supersample_ = 0;
    // ⛔ THE OFFSCREEN WALK MUST COUNT NOTHING. painted_nodes is attributed
    // CACHE-INDEPENDENTLY at the supersample hook (paintNode: `painted_ +=
    // countPaintedNodes(node) - 1`), which fires on BOTH a cache hit and miss.
    // This inner paintNode walk only happens on a MISS (renderSvgSubtreeToTexture
    // runs only when svgCache_.find misses), so letting it touch painted_ would
    // make the tally cache-dependent: a hit would count the subtree once (via the
    // hook), a miss would count it twice (hook + this walk). Save painted_ before
    // the walk and restore it after so the offscreen render leaves the counter
    // exactly as it found it — the hook is the single source of truth.
    //   NOT a `--painted_` (the old fix): that cancelled only the ROOT's extra
    //   increment and left the CHILDREN double-counted on a miss. With the hook
    //   attributing the whole subtree, the correct move is to zero this walk's
    //   contribution entirely, hence save/restore rather than a single decrement.
    const int savedPainted = painted_;
    // Reproduce the exact absolute coordinates the caller used: paintNode
    // computes x = originX + frame.origin.x, so pass origin = painted - frame.
    const float originX = x - (float)node.layoutMetrics.frame.origin.x;
    const float originY = y - (float)node.layoutMetrics.frame.origin.y;
    paintNode(off, node, originX, originY);
    supersample_ = savedN;
    painted_ = savedPainted;

    ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(off);
    if (dl) {
      ImpellerSurfaceDrawDisplayList(offscreen, dl);
      ImpellerDisplayListRelease(dl);
      glFinish();
      // Adopt the FBO's colour texture. Ownership TRANSFERS to Impeller — never
      // glDeleteTextures(colorTex) after this; the caller holds the
      // ImpellerTexture (re-adopting the same handle double-frees).
      ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888,
                                        {pxW, pxH}, 1};
      texture = ImpellerTextureCreateWithOpenGLTextureHandleNew(
          renderContext_, &desc, (uint64_t)colorTex);
    }
    ImpellerDisplayListBuilderRelease(off);
  }

  if (offscreen) ImpellerSurfaceRelease(offscreen);
  // The FBO and depth/stencil renderbuffer are OURS; free them. The colour
  // texture is NOT — Impeller owns it now (or, on the rare adoption-failure
  // path, we drop the handle: a single leaked texture, preferable to a
  // double-free).
  glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prevFbo);
  glDeleteFramebuffers(1, &fbo);
  glDeleteRenderbuffers(1, &depthStencil);
  glViewport(prevViewport[0], prevViewport[1], prevViewport[2],
             prevViewport[3]);
  return texture;
}

// ENG item 2 — one 2x downsample step. Draws `src` into a fresh dstW x dstH FBO
// with LINEAR sampling. This is an EXACT box average ONLY at a 2x reduction: a
// linear tap reads a 2x2 texel footprint, so halving averages all four source
// texels per destination texel. Reducing 4x in one linear step reads a 2x2
// footprint out of a 4x4 region and MISSES half the samples — which is why the
// caller halves iteratively (16x -> 8 -> 4 -> 2 -> 1) instead of once.
ImpellerTexture SceneGraph::halveTexture(ImpellerTexture src, int srcW,
                                         int srcH, int dstW, int dstH) {
  GLint prevFbo = 0;
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
  GLint prevViewport[4] = {0, 0, 0, 0};
  glGetIntegerv(GL_VIEWPORT, prevViewport);

  GLuint colorTex = 0, fbo = 0;
  glGenTextures(1, &colorTex);
  glBindTexture(GL_TEXTURE_2D, colorTex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, dstW, dstH, 0, GL_RGBA,
               GL_UNSIGNED_BYTE, nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         colorTex, 0);
  // No depth/stencil needed: this pass draws ONE textured quad, no path fills.

  ImpellerTexture out = nullptr;
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE) {
    ImpellerISize size = {dstW, dstH};
    ImpellerSurface surf = ImpellerSurfaceCreateWrappedFBONew(
        renderContext_, fbo, kImpellerPixelFormatRGBA8888, &size);
    if (surf) {
      ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
      // ⛔ Y-FLIP THE DRAW. `src` is read out of a wrapped GL FBO
      // (ImpellerSurfaceCreateWrappedFBONew), whose colour attachment is
      // BOTTOM-LEFT origin, while DrawTextureRect samples TOP-LEFT — so each such
      // draw comes out vertically mirrored. A negative-height srcRect does NOT
      // flip here (Impeller clamps it and fills the whole surface); flip via a
      // builder transform instead: translate down by the dst height, scale y by
      // -1. This MUST be at every FBO-texture draw: the root chain does
      // (halves + 1) such hops, so flipping only the final composite would leave
      // odd hop counts (N=2, N=8) mirrored while even counts (N=4) stay upright —
      // the exact N-dependent parity bug measured.
      ImpellerRect srcRect = {0, 0, (float)srcW, (float)srcH};
      ImpellerRect dstRect = {0, 0, (float)dstW, (float)dstH};
      ImpellerDisplayListBuilderSave(b);
      ImpellerDisplayListBuilderTranslate(b, 0, (float)dstH);
      ImpellerDisplayListBuilderScale(b, 1.0f, -1.0f);
      ImpellerDisplayListBuilderDrawTextureRect(
          b, src, &srcRect, &dstRect, kImpellerTextureSamplingLinear, nullptr);
      ImpellerDisplayListBuilderRestore(b);
      ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);
      if (dl) {
        ImpellerSurfaceDrawDisplayList(surf, dl);
        ImpellerDisplayListRelease(dl);
        glFinish();
        ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888,
                                          {dstW, dstH}, 1};
        out = ImpellerTextureCreateWithOpenGLTextureHandleNew(
            renderContext_, &desc, (uint64_t)colorTex);
      }
      ImpellerDisplayListBuilderRelease(b);
      ImpellerSurfaceRelease(surf);
    }
  }

  glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prevFbo);
  glDeleteFramebuffers(1, &fbo);
  glViewport(prevViewport[0], prevViewport[1], prevViewport[2],
             prevViewport[3]);
  return out;
}

// <world> ENG-09 — WORLD PAINTER. Reads WorldRasterStore by node name (set
// from RNSVGImageProps::name in updateFromShadowView's "world" branch, the
// SAME string JS passes to WorldRaster.setPixels) and paints the buffer as a
// textured rect at (x,y,w,h). Copies renderSvgSubtreeToTexture/halveTexture's
// GL-texture-cache shape: allocate once per node-tag, reuse across frames,
// only touch the GPU when the store's version for this node's name actually
// advanced.
//
// ⛔ THE STORE OWNS THE BYTES; WE COPY THEM INTO A GL TEXTURE, ONCE PER
// VERSION BUMP. get() (WorldRasterStore.h) returns a shared_ptr<const Entry>
// that is safe to read here without the store's lock (Entry is immutable
// after publish), but the RGBA vector itself is still the STORE's memory --
// glTexImage2D/glTexSubImage2D copy it into GPU memory synchronously before
// this function returns, so there is no lifetime hazard even though `entry`
// drops out of scope right after.
// ENG-21. The sampler a <world> draws its terrain and sprites with. Linear
// unless JS called WorldRaster.setSampling(name, 'nearest'): pixel art at an
// integer scale must not blend neighbouring texels (ROOM-1 measured 12.7% of
// room pixels holding blend colours under linear).
ImpellerTextureSampling SceneGraph::worldSampling(const SceneNode& node) const {
  return worldRasterStore_ != nullptr &&
                 worldRasterStore_->isNearest(node.worldRasterName)
             ? kImpellerTextureSamplingNearestNeighbor
             : kImpellerTextureSamplingLinear;
}

bool SceneGraph::paintWorldNode(ImpellerDisplayListBuilder builder,
                                const SceneNode& node, float x, float y,
                                float w, float h) {
  if (worldRasterStore_ == nullptr) return false;
  if (node.worldRasterName.empty()) return false;
  if (w <= 0.0f || h <= 0.0f) return false;

  std::shared_ptr<const WorldRasterEntry> entry =
      worldRasterStore_->get(node.worldRasterName);
  // Nothing has ever been published for this name -- silent no-op, the same
  // "unset image source" convention RNSVGImageShadowNode uses.
  if (entry == nullptr) return false;
  const int srcW = (int)entry->width;
  const int srcH = (int)entry->height;
  if (srcW <= 0 || srcH <= 0) return false;
  // ⛔ THE STRICT-THROW CONTRACT LIVES IN WorldRasterModule, NOT HERE, BUT
  // THIS IS THE SECOND LINE OF DEFENSE. setPixels() rejects a mismatched
  // buffer at the JS call site (see WorldRasterModule.h's header comment); a
  // buffer that somehow reached the store undersized would otherwise read out
  // of bounds in glTexImage2D/glTexSubImage2D below.
  if (entry->pixels.size() < (size_t)srcW * (size_t)srcH * 4) return false;

  WorldTextureEntry& cacheEntry = worldTextureCache_[node.tag];
  const bool sizeChanged =
      cacheEntry.glTex == 0 || cacheEntry.texW != srcW || cacheEntry.texH != srcH;

  if (sizeChanged) {
    // First frame for this node, or its buffer's dimensions changed --
    // (re)allocate.
    //
    // ⛔ A RESIZE NEEDS A FRESH GL NAME. RELEASE FIRST, THEN glGenTextures.
    // ImpellerTextureCreateWithOpenGLTextureHandleNew TAKES OWNERSHIP of the
    // handle: Impeller calls glDeleteTextures on it when the last reference
    // drops (impeller.h, "Ownership of the handle is transferred"). The old
    // order reused the adopted name: glTexImage2D the new pixels into it,
    // THEN release the old wrapper, which DELETED that name along with the
    // pixels just uploaded, THEN adopt the dead name. Every frame after a
    // size change sampled a texture with no storage: pure black terrain on
    // Mesa, with world_sprites_drawn and scene_nodes still reporting success.
    // Measured by tools/ci-world-resize.sh (a 160x120 -> 320x240 swap
    // mid-session). Once adopted, the name belongs to Impeller; never reuse it.
    if (cacheEntry.texture) {
      ImpellerTextureRelease(cacheEntry.texture);
      cacheEntry.texture = nullptr;
      cacheEntry.glTex = 0;  // Impeller deletes it; it is no longer ours
    }
    if (cacheEntry.glTex == 0) {
      GLuint tex = 0;
      glGenTextures(1, &tex);
      cacheEntry.glTex = tex;
    }
    glBindTexture(GL_TEXTURE_2D, cacheEntry.glTex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, srcW, srcH, 0, GL_RGBA,
                GL_UNSIGNED_BYTE, entry->pixels.data());
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    cacheEntry.texW = srcW;
    cacheEntry.texH = srcH;
    cacheEntry.uploadedVersion = entry->version;
    ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888,
                                      {srcW, srcH}, 1};
    cacheEntry.texture = ImpellerTextureCreateWithOpenGLTextureHandleNew(
        renderContext_, &desc, (uint64_t)cacheEntry.glTex);
  } else if (entry->version != cacheEntry.uploadedVersion) {
    // Same dimensions, new pixels -- a partial update via glTexSubImage2D is
    // the whole point of tracking uploadedVersion: re-running glTexImage2D
    // every frame would reallocate GPU storage for a texture that never
    // changed size, which is wasteful and is exactly what glTexSubImage2D
    // avoids.
    glBindTexture(GL_TEXTURE_2D, cacheEntry.glTex);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, srcW, srcH, GL_RGBA,
                    GL_UNSIGNED_BYTE, entry->pixels.data());
    cacheEntry.uploadedVersion = entry->version;
  }

  if (cacheEntry.texture == nullptr) return false;

  // ⛔ NO Y-FLIP HERE — AND THAT IS THE FIX, NOT AN OVERSIGHT.
  //
  // Every OTHER ImpellerTextureCreateWithOpenGLTextureHandleNew call in this
  // file (renderSvgSubtreeToTexture, halveTexture, the root/icon supersample
  // composites) wraps an FBO's COLOUR ATTACHMENT: GL renders into that FBO
  // bottom-up (window-coordinate convention, v=0 at the bottom), so reading
  // it back as a texture and drawing it right-side-up needs the
  // translate+scale(-1) flip those call sites all share.
  //
  // This texture is different: it is populated by glTexImage2D/
  // glTexSubImage2D directly from WorldRasterStore's CPU buffer, above --
  // there is no FBO render pass, no GL window-coordinate origin in play at
  // all. Row 0 of the buffer becomes row 0 of the texture's storage exactly
  // as uploaded, and Impeller samples a plain 2D texture with a top-left
  // origin (the same convention the CPU buffer and WorldRaster's JS contract
  // both use). Applying the FBO-pattern flip here draws the buffer upside
  // down — measured directly: tools/mutation-verify-world-raster.sh's M3
  // seed (re-adding this flip) fails tools/ci-world-raster.sh's positional
  // luma check with every off-centre sample point mismatched by ~200 levels,
  // and the two renders are pixel-for-pixel identical with it removed.
  ImpellerRect srcRect = {0, 0, (float)srcW, (float)srcH};
  ImpellerRect dstRect = {0, 0, w, h};
  ImpellerDisplayListBuilderSave(builder);
  ImpellerDisplayListBuilderTranslate(builder, x, y);
  ImpellerDisplayListBuilderDrawTextureRect(builder, cacheEntry.texture,
                                            &srcRect, &dstRect,
                                            worldSampling(node),  // ENG-21
                                            nullptr);
  ImpellerDisplayListBuilderRestore(builder);
  // ⛔ DO NOT RELEASE cacheEntry.texture HERE. It is cached across frames in
  // worldTextureCache_ (unlike the per-icon svgCache_'s LRU eviction, this
  // cache is unbounded -- one <world> app mounts a small, fixed number of
  // these nodes, not an unbounded scrolling list) and the deferred host draw
  // that consumes `builder`'s display list runs after paint() returns.
  return true;
}

// <world> ENG-10. GPU sprite compositing. Draws the store's drawSprites list
// for this node's name, in LIST ORDER (back-to-front: painter's algorithm falls
// out of order for free), one DrawTextureRect per sprite, over whatever the
// node already painted (the setPixels terrain, or its own background).
//
// Atlas textures are keyed by textureId and uploaded ONCE per registerSprite
// version -- the per-frame cost is list parsing + N texture-rect draws, zero
// texture uploads. That is the whole point vs the ENG-09 path, where JS
// composites every sprite into one CPU buffer and re-uploads it per frame.
//
// ⛔ NO Y-FLIP, SAME RULE AS paintWorldNode. Atlas textures are glTexImage2D'd
// straight from CPU top-left-origin buffers -- no FBO pass. Copying the FBO
// composite's translate+scale(1,-1) here draws every sprite upside down;
// tools/mutation-verify-world-sprites.sh's M-flip seeds exactly that.
bool SceneGraph::paintWorldSprites(ImpellerDisplayListBuilder builder,
                                   const SceneNode& node, float x, float y,
                                   float w, float h) {
  if (worldRasterStore_ == nullptr) return false;
  if (node.worldRasterName.empty()) return false;
  if (w <= 0.0f || h <= 0.0f) return false;
  std::shared_ptr<const WorldSpriteList> list =
      worldRasterStore_->getSprites(node.worldRasterName);
  if (list == nullptr || list->sprites.empty()) return false;

  // Resolve each distinct textureId ONCE per frame (one store lock each, not
  // one per sprite), uploading on first sight or when its registerSprite
  // version advanced.
  std::unordered_map<std::string, const WorldTextureEntry*> resolved;
  auto resolve = [&](const std::string& textureId) -> const WorldTextureEntry* {
    auto hit = resolved.find(textureId);
    if (hit != resolved.end()) return hit->second;
    const WorldTextureEntry* out = nullptr;
    std::shared_ptr<const WorldRasterEntry> src =
        worldRasterStore_->getSprite(textureId);
    const int srcW = src ? (int)src->width : 0;
    const int srcH = src ? (int)src->height : 0;
    if (src && srcW > 0 && srcH > 0 &&
        src->pixels.size() >= (size_t)srcW * (size_t)srcH * 4) {
      WorldTextureEntry& e = spriteTextureCache_[textureId];
      const bool sizeChanged = e.glTex == 0 || e.texW != srcW || e.texH != srcH;
      if (sizeChanged) {
        // ⛔ Same ownership rule as paintWorldNode: the adopted name is
        // Impeller's and dies with the old wrapper. Release FIRST, then take a
        // fresh name, or a re-registered sprite of a new size adopts a deleted
        // texture and draws black.
        if (e.texture) {
          ImpellerTextureRelease(e.texture);
          e.texture = nullptr;
          e.glTex = 0;
        }
        if (e.glTex == 0) {
          GLuint tex = 0;
          glGenTextures(1, &tex);
          e.glTex = tex;
        }
        glBindTexture(GL_TEXTURE_2D, e.glTex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, srcW, srcH, 0, GL_RGBA,
                     GL_UNSIGNED_BYTE, src->pixels.data());
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        e.texW = srcW;
        e.texH = srcH;
        e.uploadedVersion = src->version;
        ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888,
                                          {srcW, srcH}, 1};
        e.texture = ImpellerTextureCreateWithOpenGLTextureHandleNew(
            renderContext_, &desc, (uint64_t)e.glTex);
      } else if (src->version != e.uploadedVersion) {
        glBindTexture(GL_TEXTURE_2D, e.glTex);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, srcW, srcH, GL_RGBA,
                        GL_UNSIGNED_BYTE, src->pixels.data());
        e.uploadedVersion = src->version;
      }
      if (e.texture) out = &e;
    }
    resolved.emplace(textureId, out);
    return out;
  };

  // ENG-21: one sampler for every sprite on this world, resolved once.
  const ImpellerTextureSampling sampling = worldSampling(node);
  ImpellerDisplayListBuilderSave(builder);
  ImpellerDisplayListBuilderTranslate(builder, x, y);
  // Sprites are positioned in the <world> node's own coordinate space; one
  // that hangs off the edge is clipped to the node, like a canvas would.
  ImpellerRect clip = {0, 0, w, h};
  ImpellerDisplayListBuilderClipRect(builder, &clip,
                                     kImpellerClipOperationIntersect);
  for (const WorldSprite& s : list->sprites) {
    if (s.w <= 0.0f || s.h <= 0.0f || s.alpha <= 0.0f) continue;
    const WorldTextureEntry* tex = resolve(s.textureId);
    if (tex == nullptr) continue;
    ImpellerRect srcRect = {0, 0, (float)tex->texW, (float)tex->texH};
    ImpellerRect dstRect = {s.x, s.y, s.w, s.h};
    // Per-sprite globalAlpha: the paint's colour alpha modulates the
    // (premultiplied) texture. Opaque sprites pass no paint at all.
    ImpellerPaint alphaPaint = nullptr;
    if (s.alpha < 1.0f) {
      alphaPaint = ImpellerPaintNew();
      ImpellerColor c = {1.0f, 1.0f, 1.0f, s.alpha, kImpellerColorSpaceSRGB};
      ImpellerPaintSetColor(alphaPaint, &c);
    }
    ImpellerDisplayListBuilderDrawTextureRect(builder, tex->texture, &srcRect,
                                              &dstRect, sampling, alphaPaint);
    if (alphaPaint) ImpellerPaintRelease(alphaPaint);
    ++spritesDrawn_;
  }
  ImpellerDisplayListBuilderRestore(builder);
  // ⛔ Textures stay cached in spriteTextureCache_ (the pending display list
  // references them after paint() returns); released in the destructor.
  return true;
}

// ENG item 2 — SUPERSAMPLE-RNSVG. Render the <Svg> root subtree at N x into an
// offscreen, halve it down toward native resolution, then composite the result
// with a final LINEAR downsample. Each halving is an exact box average, so the
// chain synthesises the partial-coverage edge pixels Impeller's tessellated
// stroke path refuses to emit — at any N, not just N=2.
//
// ⛔ CALLED DURING DISPLAY-LIST RECORDING, NOT DURING A LIVE DRAW. paintNode is
// building `builder`'s command list; the main surface is not being drawn to yet
// (main.cpp draws the finished list afterwards). So issuing GL here and drawing
// the offscreen lists immediately is safe. Every FBO helper saves/restores the
// prior FBO binding + viewport, so the surface init's own bindings survive.
// Counts how many ++painted_ increments a real paintNode() walk of this subtree
// would make — WITHOUT painting anything. Used by the supersample hook so the
// painted_nodes tally is cache-independent (the offscreen render walks children
// only on a cache miss and is counter-suppressed). This MUST mirror paintNode's
// traversal exactly, or the tally drifts from the node_frame lines:
//   * +1 for the node itself (paintNode does ++painted_ at its top);
//   * a definition subtree (<Defs>/<Symbol>) counts ONLY itself — paintNode
//     early-returns before its child walk, so its children are not counted here;
//   * otherwise each child is counted;
//   * a <Use> re-enters the referenced definition's CHILDREN (not the def node),
//     bounded by kMaxUseDepth exactly as the painter is.
int SceneGraph::countPaintedNodes(const SceneNode& node, int useDepth) {
  int n = 1;  // paintNode's ++painted_ for this node
  if (node.isSvgDefinition) return n;  // early return before the child walk
  for (auto childTag : node.children) {
    auto it = nodes_.find(childTag);
    if (it != nodes_.end()) n += countPaintedNodes(it->second, useDepth);
  }
  if (node.isSvgUse && !node.svgUseHref.empty() && useDepth < kMaxUseDepth) {
    auto def = svgDefs_.find(node.svgUseHref);
    if (def != svgDefs_.end() && def->second != nullptr) {
      for (auto defChild : def->second->children) {
        auto ct = nodes_.find(defChild);
        if (ct != nodes_.end()) n += countPaintedNodes(ct->second, useDepth + 1);
      }
    }
  }
  return n;
}

bool SceneGraph::paintSvgRootSupersampled(ImpellerDisplayListBuilder builder,
                                          const SceneNode& node, float x,
                                          float y, float w, float h) {
  const int N = supersample_;
  if (N < 1 || w <= 0.0f || h <= 0.0f) return false;

  // Native pixel size of the icon's painted box, and the N x offscreen size.
  // Bounded so a pathological full-screen SVG at N=4 cannot ask for a 16k
  // texture and OOM the GPU; past the bound we fall back to in-place.
  //
  // ⛔ ENG-05b: DEVICE PIXELS, NOT POINTS. w/h are points, and the composite
  // below is drawn under paint()'s root pointScale transform, so the icon
  // covers w*S x h*S pixels on screen. Sized in points, a Retina (S=2) frame
  // got only N/S x supersampling: 4 edge levels at N=4 instead of 16. That is
  // the live case on the Mac, because a Retina window wider than 1024 pt is
  // too big for the whole-tree offscreen and lands here.
  const float S = pointScale_ > 0.0f ? pointScale_ : 1.0f;
  const int nativeW = std::max(1, (int)std::ceil(w * S));
  const int nativeH = std::max(1, (int)std::ceil(h * S));
  const int pxW = (int)std::ceil(w * S * (float)N);
  const int pxH = (int)std::ceil(h * S * (float)N);
  if (pxW <= 0 || pxH <= 0 || pxW > 8192 || pxH > 8192) return false;

  const std::string key = svgSubtreeCacheKey(node, pxW, pxH);

  ImpellerTexture texture = nullptr;
  int texW = 0, texH = 0;
  auto cacheIt = svgCache_.find(key);
  if (cacheIt != svgCache_.end()) {
    texture = cacheIt->second.texture;
    texW = cacheIt->second.texW;
    texH = cacheIt->second.texH;
    // Touch LRU: move this key to the back (most-recently-used).
    auto oit = std::find(svgCacheOrder_.begin(), svgCacheOrder_.end(), key);
    if (oit != svgCacheOrder_.end()) svgCacheOrder_.erase(oit);
    svgCacheOrder_.push_back(key);
  } else {
    // 1. Rasterise the subtree at full N x.
    ImpellerTexture cur = renderSvgSubtreeToTexture(node, x, y, w, h, pxW, pxH);
    if (cur == nullptr) return false;  // fall back to in-place
    int curW = pxW, curH = pxH;

    // 2. Halve repeatedly until within 2x of native. Each step is an exact box
    //    average; stopping at 2x leaves the final 2x reduction to the composite
    //    DrawTextureRect below, which is itself an exact 2x box average. This is
    //    what makes N=4, 8, 16 antialias instead of degenerating to point
    //    sampling (a single linear tap cannot average more than a 2x2 footprint).
    int guard = 0;
    while ((curW > nativeW * 2 || curH > nativeH * 2) && guard++ < 16) {
      const int nW = std::max(nativeW, curW / 2);
      const int nH = std::max(nativeH, curH / 2);
      ImpellerTexture half = halveTexture(cur, curW, curH, nW, nH);
      ImpellerTextureRelease(cur);  // done with this level
      if (half == nullptr) return false;
      cur = half;
      curW = nW;
      curH = nH;
    }
    texture = cur;
    texW = curW;
    texH = curH;

    // Insert into the cache and evict LRU past the bound.
    svgCache_[key] = SvgCacheEntry{texture, texW, texH};
    svgCacheOrder_.push_back(key);
    while (svgCacheOrder_.size() > kSvgCacheMax) {
      const std::string& victim = svgCacheOrder_.front();
      auto vit = svgCache_.find(victim);
      if (vit != svgCache_.end()) {
        if (vit->second.texture) ImpellerTextureRelease(vit->second.texture);
        svgCache_.erase(vit);
      }
      svgCacheOrder_.erase(svgCacheOrder_.begin());
    }
  }

  if (texture == nullptr) return false;

  // ---- Composite the (near-native) offscreen into the main builder. ----
  // ⛔ THIS DRAW IS LOAD-BEARING. Without it the hook builds and caches the
  // texture, returns true, and paintNode (the caller) SKIPS the in-place walk —
  // so the icon paints NOTHING. That is the "icons vanish at N=1/N=8" bug: N=1
  // is the only path that reaches this hook (root supersample is gated N>=2),
  // and N=8 reaches it when the root offscreen exceeds the GPU bound and falls
  // through with supersample_ still set. The icon's background View still paints
  // (separate node), leaving a bare rounded tile with no glyph.
  //
  // ⛔ LINEAR sampling IS the anti-aliasing. Nearest-neighbour would pick one
  // sub-pixel and reproduce the binary edge — the N=1 round-trip's result. The
  // halving chain left the texture at <=2x native, so this final draw is at most
  // a 2x reduction and its single linear tap is an exact box average.
  //
  // ⛔ Y-FLIP THE DRAW — the wrapped GL FBO is bottom-left origin while
  // DrawTextureRect samples top-left, so an unflipped composite is vertically
  // mirrored. Same reason and mechanism as halveTexture and the root composite:
  // a builder transform (translate to the box's bottom, scale y by -1), because
  // a negative-height srcRect is clamped by Impeller and fills the surface. The
  // icon box is at (x,y) size (w,h), so the flip pivots on THIS box, not (0,0).
  ImpellerRect srcRect = {0, 0, (float)texW, (float)texH};
  ImpellerRect dstRect = {0, 0, w, h};
  ImpellerDisplayListBuilderSave(builder);
  ImpellerDisplayListBuilderTranslate(builder, x, y + h);
  ImpellerDisplayListBuilderScale(builder, 1.0f, -1.0f);
  ImpellerDisplayListBuilderDrawTextureRect(builder, texture, &srcRect, &dstRect,
                                            kImpellerTextureSamplingLinear,
                                            nullptr);
  ImpellerDisplayListBuilderRestore(builder);
  // ⛔ DO NOT RELEASE `texture` HERE. The host draws `builder`'s display list
  // AFTER paint() returns, and it references this texture. Unlike the root path
  // (which double-buffers via treeTexture_), the per-icon texture is owned by
  // svgCache_ — it stays alive until LRU eviction past kSvgCacheMax or the
  // destructor, which is well after the deferred host draw consumes the list.
  return true;
}

// ENG item 2b — ROOT SUPERSAMPLE. Whole tree -> one N x offscreen -> iterative
// halve -> single composite in device pixels. Same box-filter chain as the
// per-icon path (renderSvgSubtreeToTexture + halveTexture), lifted to the root so
// primitives Impeller does not edge-antialias itself (a View's stroked rounded
// border) get the synthesised partial-coverage edges too.
bool SceneGraph::paintTreeSupersampled(ImpellerDisplayListBuilder builder,
                                       float pointScaleFactor) {
  const int N = supersample_;
  if (N < 2 || renderContext_ == nullptr) return false;      // <2 = in-place/mutant
  if (surfacePxW_ <= 0 || surfacePxH_ <= 0) return false;     // host never wired size
  const int nativeW = surfacePxW_;
  const int nativeH = surfacePxH_;
  const int pxW = nativeW * N;
  const int pxH = nativeH * N;
  // Same 8192/axis GPU bound as the icon path. A surface large enough that N x
  // overflows it (e.g. a 5K window at N>=2) falls back to the in-place walk,
  // which STILL runs the per-<Svg>-root hook — so icons keep their AA and only
  // View borders on an oversize surface lose it. A strict superset of b9edbee.
  if (pxW <= 0 || pxH <= 0 || pxW > 8192 || pxH > 8192) return false;

  GLint prevFbo = 0;
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
  GLint prevViewport[4] = {0, 0, 0, 0};
  glGetIntegerv(GL_VIEWPORT, prevViewport);

  GLuint colorTex = 0, fbo = 0, depthStencil = 0;
  glGenTextures(1, &colorTex);
  glBindTexture(GL_TEXTURE_2D, colorTex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, pxW, pxH, 0, GL_RGBA,
               GL_UNSIGNED_BYTE, nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         colorTex, 0);
  // Depth+stencil for the same reason renderSvgSubtreeToTexture attaches it: any
  // concave fill in the tree is stencil-then-cover and paints its bounding box
  // without a stencil buffer.
  glGenRenderbuffers(1, &depthStencil);
  glBindRenderbuffer(GL_RENDERBUFFER, depthStencil);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, pxW, pxH);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                            GL_RENDERBUFFER, depthStencil);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT,
                            GL_RENDERBUFFER, depthStencil);

  ImpellerTexture texture = nullptr;
  int texW = 0, texH = 0;
  bool ok = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  ImpellerSurface offscreen = nullptr;
  if (ok) {
    ImpellerISize size = {pxW, pxH};
    offscreen = ImpellerSurfaceCreateWrappedFBONew(
        renderContext_, fbo, kImpellerPixelFormatRGBA8888, &size);
    ok = offscreen != nullptr;
  }
  if (ok) {
    ImpellerDisplayListBuilder off = ImpellerDisplayListBuilderNew(nullptr);
    // points -> N x device pixels: the same root scale paint() applies, times N.
    const float s = pointScaleFactor * (float)N;
    ImpellerDisplayListBuilderScale(off, s, s);
    // ⛔ SUPPRESS THE PER-<Svg>-ROOT HOOK for the inner walk. With supersample_
    // still >=2, paintNode would take paintSvgRootSupersampled for each icon —
    // supersampling twice (wasteful) and, worse, at a scale the icon path does
    // not expect. Zero it so the inner walk is a plain in-place render; restore
    // after. The root offscreen already supersamples the icons along with
    // everything else.
    const int savedN = supersample_;
    supersample_ = 0;
    for (auto rootTag : roots_) {
      auto it = nodes_.find(rootTag);
      if (it == nodes_.end()) continue;
      paintNode(off, it->second, 0, 0);
    }
    supersample_ = savedN;

    ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(off);
    if (dl) {
      ImpellerSurfaceDrawDisplayList(offscreen, dl);
      ImpellerDisplayListRelease(dl);
      glFinish();
      ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888,
                                        {pxW, pxH}, 1};
      texture = ImpellerTextureCreateWithOpenGLTextureHandleNew(
          renderContext_, &desc, (uint64_t)colorTex);
      texW = pxW;
      texH = pxH;
    }
    ImpellerDisplayListBuilderRelease(off);
  }

  if (offscreen) ImpellerSurfaceRelease(offscreen);
  glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prevFbo);
  glDeleteFramebuffers(1, &fbo);
  glDeleteRenderbuffers(1, &depthStencil);
  glViewport(prevViewport[0], prevViewport[1], prevViewport[2],
             prevViewport[3]);

  if (texture == nullptr) return false;  // fall back to in-place walk

  // Halve iteratively to within 2x native; the final composite is the last 2x
  // box average. Exactly the icon path's reasoning: one linear tap averages a
  // 2x2 footprint, so reducing N x in one step would point-sample.
  {
    int guard = 0;
    while ((texW > nativeW * 2 || texH > nativeH * 2) && guard++ < 16) {
      const int nW = std::max(nativeW, texW / 2);
      const int nH = std::max(nativeH, texH / 2);
      ImpellerTexture half = halveTexture(texture, texW, texH, nW, nH);
      ImpellerTextureRelease(texture);
      if (half == nullptr) return false;  // fall back; frame paints in place
      texture = half;
      texW = nW;
      texH = nH;
    }
  }

  // ---- Composite in DEVICE PIXELS. ----
  // paint() applies its pointScaleFactor scale around the in-place walk; the
  // supersample path does NOT (see paint()), so this draws straight into the
  // device-pixel framebuffer at the surface's full extent. LINEAR sampling IS
  // the AA: because the texture is <=2x native, this final draw is at most a 2x
  // box average.
  // ⛔ Y-FLIP THE DRAW — same wrapped-FBO bottom-left-origin reason as
  // halveTexture, via a builder transform (negative-height srcRect is unsupported
  // and fills the whole surface). This final composite is one FBO-texture hop;
  // combined with the per-hop flip in halveTexture, every N (halves+1 hops)
  // lands upright.
  ImpellerRect srcRect = {0, 0, (float)texW, (float)texH};
  ImpellerRect dstRect = {0, 0, (float)nativeW, (float)nativeH};
  ImpellerDisplayListBuilderSave(builder);
  ImpellerDisplayListBuilderTranslate(builder, 0, (float)nativeH);
  ImpellerDisplayListBuilderScale(builder, 1.0f, -1.0f);
  ImpellerDisplayListBuilderDrawTextureRect(builder, texture, &srcRect, &dstRect,
                                            kImpellerTextureSamplingLinear,
                                            nullptr);
  ImpellerDisplayListBuilderRestore(builder);
  // ⛔ DO NOT RELEASE `texture` HERE. The host draws `builder`'s display list
  // AFTER paint() returns, and it references this texture. Double-buffer it:
  // free the PREVIOUS frame's tree texture (its display list is long consumed)
  // and hold this one for the next frame / the destructor.
  if (treeTexture_) ImpellerTextureRelease(treeTexture_);
  treeTexture_ = texture;
  return true;
}
#endif  // RNI_SUPERSAMPLE_GL

// Borders are drawn EDGE BY EDGE, as filled trapezoids, not as a stroked rect.
//
// A stroke cannot express four different colours, and it straddles the path
// (half in, half out) so a 12px border reads 6px wide at the frame edge — which
// makes an edge-midpoint probe land on background and looks like "borders do
// not paint". RN's border box is strictly INSIDE the frame, so each edge is the
// quad between the outer rect and the inset content rect, mitred at the corners.
void SceneGraph::paintBorders(ImpellerDisplayListBuilder builder,
                              const SceneNode& node, float x, float y, float w,
                              float h, const ImpellerRoundingRadii& radii,
                              bool rounded) {
  const float t = node.borderWidths[0], r = node.borderWidths[1];
  const float b = node.borderWidths[2], l = node.borderWidths[3];
  if (t <= 0 && r <= 0 && b <= 0 && l <= 0) return;

  // Uniform colour + uniform width + rounded: a stroked rounded rect follows the
  // curve properly, which mitred quads would not. Inset by half the width so the
  // stroke sits inside the frame like RN's box model says.
  const bool uniformWidth = (t == r && r == b && b == l);
  bool uniformColor = true;
  for (int i = 1; i < 4; ++i) {
    if (node.hasBorderColors[i] != node.hasBorderColors[0]) { uniformColor = false; break; }
    for (int c = 0; c < 4; ++c) {
      if (node.borderColors[i][c] != node.borderColors[0][c]) { uniformColor = false; break; }
    }
    if (!uniformColor) break;
  }

  // B5: dashed / dotted on a rounded box or with per-side colours (uniform width).
  if (node.borderStyle != 0 && uniformWidth && (rounded || !uniformColor)) {
    ImpellerColor dc[4];
    bool dv[4];
    for (int e = 0; e < 4; ++e) {
      dc[e] = impellerColor(node.borderColors[e], OwnAlpha(node));
      dv[e] = node.hasBorderColors[e] && node.borderColors[e][3] > 0.0f;
    }
    if (PaintDashedRoundedBorder(builder, node.borderStyle, x, y, w, h, t, dc, dv, radii)) {
      return;
    }
  }

  // Items 10 + 25: dashed / dotted, uniform width + colour on a square box
  // (scenegraph/BorderDash.h has the RN iOS dash geometry). Rounded dashed borders
  // fall through to the solid rounded stroke below; not claimed.
  if (node.borderStyle != 0 && !rounded && uniformWidth && uniformColor &&
      node.hasBorderColors[0] && node.borderColors[0][3] > 0.0f) {
    if (PaintDashedBorder(builder, node.borderStyle, x, y, w, h, t,
                          impellerColor(node.borderColors[0], OwnAlpha(node)))) {
      return;
    }
  }

  if (rounded && uniformWidth && uniformColor) {
    if (!node.hasBorderColors[0] || node.borderColors[0][3] <= 0.0f) return;
    ImpellerPaint paint = ImpellerPaintNew();
    ImpellerColor c = impellerColor(node.borderColors[0], OwnAlpha(node));
    ImpellerPaintSetColor(paint, &c);
    ImpellerPaintSetDrawStyle(paint, kImpellerDrawStyleStroke);
    ImpellerPaintSetStrokeWidth(paint, t);
    ImpellerRect inset = {x + t * 0.5f, y + t * 0.5f, w - t, h - t};
    ImpellerRoundingRadii ir = radii;
    ir.top_left = {std::max(0.0f, radii.top_left.x - t * 0.5f),
                   std::max(0.0f, radii.top_left.y - t * 0.5f)};
    ir.bottom_left = {std::max(0.0f, radii.bottom_left.x - t * 0.5f),
                      std::max(0.0f, radii.bottom_left.y - t * 0.5f)};
    ir.top_right = {std::max(0.0f, radii.top_right.x - t * 0.5f),
                    std::max(0.0f, radii.top_right.y - t * 0.5f)};
    ir.bottom_right = {std::max(0.0f, radii.bottom_right.x - t * 0.5f),
                       std::max(0.0f, radii.bottom_right.y - t * 0.5f)};
    ImpellerDisplayListBuilderDrawRoundedRect(builder, &inset, &ir, paint);
    ImpellerPaintRelease(paint);
    return;
  }

  if (rounded) {
    const float widths4[4] = {t, r, b, l};
    ImpellerColor cols[4];
    bool vis[4];
    for (int e = 0; e < 4; ++e) {
      cols[e] = impellerColor(node.borderColors[e], OwnAlpha(node));
      vis[e] = node.hasBorderColors[e] && node.borderColors[e][3] > 0.0f;
    }
    PaintRoundedMixedBorder(builder, x, y, w, h, widths4, cols, vis, radii);
    return;
  }

  // Outer corners, and the inner (content-box) corners the mitres run to.
  const float ox0 = x, oy0 = y, ox1 = x + w, oy1 = y + h;
  const float ix0 = x + l, iy0 = y + t, ix1 = x + w - r, iy1 = y + h - b;

  struct Quad { float px[4], py[4]; };
  const Quad quads[4] = {
      // top: outer top edge down to the inner top edge, mitred both ends
      {{ox0, ox1, ix1, ix0}, {oy0, oy0, iy0, iy0}},
      // right
      {{ox1, ox1, ix1, ix1}, {oy0, oy1, iy1, iy0}},
      // bottom
      {{ox1, ox0, ix0, ix1}, {oy1, oy1, iy1, iy1}},
      // left
      {{ox0, ox0, ix0, ix0}, {oy1, oy0, iy0, iy1}},
  };
  const float widths[4] = {t, r, b, l};

  for (int e = 0; e < 4; ++e) {
    if (widths[e] <= 0.0f) continue;
    if (!node.hasBorderColors[e] || node.borderColors[e][3] <= 0.0f) continue;
    ImpellerPathBuilder pb = ImpellerPathBuilderNew();
    ImpellerPoint p0 = {quads[e].px[0], quads[e].py[0]};
    ImpellerPathBuilderMoveTo(pb, &p0);
    for (int k = 1; k < 4; ++k) {
      ImpellerPoint p = {quads[e].px[k], quads[e].py[k]};
      ImpellerPathBuilderLineTo(pb, &p);
    }
    ImpellerPathBuilderClose(pb);
    ImpellerPath path =
        ImpellerPathBuilderTakePathNew(pb, kImpellerFillTypeNonZero);
    if (path != nullptr) {
      ImpellerPaint paint = ImpellerPaintNew();
      ImpellerColor c = impellerColor(node.borderColors[e], OwnAlpha(node));
      ImpellerPaintSetColor(paint, &c);
      ImpellerDisplayListBuilderDrawPath(builder, path, paint);
      ImpellerPaintRelease(paint);
      ImpellerPathRelease(path);
    }
    ImpellerPathBuilderRelease(pb);
  }
}

ImpellerColorSource SceneGraph::makeGradientSource(const SceneNode* def,
                                                   float x, float y, float w,
                                                   float h, float alpha) const {
  if (def == nullptr) return nullptr;
  const auto& g = def->svgGradientStops;
  // Flat [offset, argb, offset, argb, ...]; anything else is a shape we do not
  // understand and must not guess at.
  if (g.size() < 4 || (g.size() % 2) != 0) return nullptr;

  const size_t n = g.size() / 2;
  std::vector<ImpellerColor> colors(n);
  std::vector<float> stops(n);
  for (size_t i = 0; i < n; ++i) {
    stops[i] = g[i * 2];
    // ⛔ THE STOP COLOUR ARRIVES AS A **NEGATIVE** FLOAT, AND THAT IS NOT THE
    // SAME AS THE FILL BRUSH'S PAYLOAD.
    //
    // Measured at runtime: red = -65536.0, blue = -16776961.0,
    // white = -1.0 -- i.e. the packed ARGB reinterpreted as a SIGNED int32,
    // because rnsvg pushes processColor()'s signed result straight into the
    // same numeric vector as the offsets. The fill brush's `payload`, which
    // crosses as JSON, arrives POSITIVE (4294901760) instead.
    //
    // So the two colour paths in this file have different signs for the same
    // colour, and int64 here is not load-bearing the way it is for `payload`
    // (an int32 cast gives an identical result for negative values -- verified
    // as an equivalent mutant). It stays int64 so BOTH representations decode
    // correctly if rnsvg ever changes which one it sends.
    const auto argb = static_cast<uint32_t>(static_cast<int64_t>(g[i * 2 + 1]));
    float c[4];
    c[3] = (float)((argb >> 24) & 0xFF) / 255.0f;
    c[0] = (float)((argb >> 16) & 0xFF) / 255.0f;
    c[1] = (float)((argb >> 8) & 0xFF) / 255.0f;
    c[2] = (float)(argb & 0xFF) / 255.0f;
    colors[i] = impellerColor(c, c[3] * alpha);
  }

  // gradientUnits: 0 = objectBoundingBox (coords are 0..1 fractions of the
  // referencing shape's box), 1 = userSpaceOnUse (absolute user units).
  const bool bbox = (def->svgGradientUnits == 0);
  auto mapX = [&](float v) { return bbox ? x + v * w : x + v; };
  auto mapY = [&](float v) { return bbox ? y + v * h : y + v; };

  if (!def->svgGradientRadial) {
    ImpellerPoint p0 = {mapX(def->svgGradientCoords[0]),
                        mapY(def->svgGradientCoords[1])};
    ImpellerPoint p1 = {mapX(def->svgGradientCoords[2]),
                        mapY(def->svgGradientCoords[3])};
    return ImpellerColorSourceCreateLinearGradientNew(
        &p0, &p1, (uint32_t)n, colors.data(), stops.data(),
        kImpellerTileModeClamp, nullptr);
  }

  // ⚠️ Impeller's radial gradient is CIRCULAR -- one radius, no focal point.
  // SVG's is an ellipse (rx, ry) with an optional focus. Using the mean radius
  // is a documented approximation, NOT parity: an SVG radial with rx != ry
  // renders as a circle here. Recorded in docs/STATE.md rather than silently
  // shipped as if correct.
  ImpellerPoint centre = {mapX(def->svgGradientCoords[4]),
                          mapY(def->svgGradientCoords[5])};
  const float rx = bbox ? def->svgGradientCoords[2] * w : def->svgGradientCoords[2];
  const float ry = bbox ? def->svgGradientCoords[3] * h : def->svgGradientCoords[3];
  const float radius = (rx + ry) * 0.5f;
  if (radius <= 0.0f) return nullptr;
  return ImpellerColorSourceCreateRadialGradientNew(
      &centre, radius, (uint32_t)n, colors.data(), stops.data(),
      kImpellerTileModeClamp, nullptr);
}

int SceneGraph::paint(ImpellerDisplayListBuilder builder,
                      float pointScaleFactor) {
  std::lock_guard<std::mutex> lock(mutex_);
  // Rebuild the gradient registry before walking the tree: a def may be
  // declared anywhere (usually inside <Defs>, which never paints), so it
  // cannot be resolved during the walk itself.
  gradients_.clear();
  svgDefs_.clear();
  for (const auto& [tag, n] : nodes_) {
    if (n.isSvgGradient && !n.svgGradientName.empty()) {
      gradients_[n.svgGradientName] = &n;
    }
    // Symbol definitions, keyed by id, for <Use href="#id">. Same rebuild-per-
    // frame rule as gradients: a <Use> can appear before its <Symbol>.
    if (n.isSvgDefinition && !n.svgDefName.empty()) {
      svgDefs_[n.svgDefName] = &n;
    }
  }
  svgUseDepth_ = 0;
#if RNI_SUPERSAMPLE_GL
  // ENG item 2b — ROOT SUPERSAMPLE HOOK. At N>=2 with a wired context and known
  // surface size, render the WHOLE tree into one N x offscreen and composite it
  // back with a linear downsample — antialiasing primitives Impeller does not
  // edge-antialias itself (a View's stroked rounded border). Composites in
  // device pixels, so it does its OWN root scale; the scaled in-place walk below
  // is skipped when it succeeds. A failure (no context, oversize surface, GL
  // error) returns false and falls through to the exact in-place walk, so a
  // broken offscreen degrades to a correct-but-aliased frame, never a blank one.
  // N=0 (disabled) and N=1 (the mutant control) never enter here — they take the
  // in-place walk and paint the flat, un-antialiased edge the gate proves.
  pointScale_ = pointScaleFactor > 0.0f ? pointScaleFactor : 1.0f;  // elevation DPR
  if (supersample_ >= 2 && paintTreeSupersampled(builder, pointScaleFactor)) {
    // painted_ is incremented inside the inner walk paintTreeSupersampled ran,
    // so it already reflects the visited node count.
    return painted_;
  }
#endif
  // ⛔ SCALE ONCE, AT THE ROOT — NOT PER NODE.
  // The tree's frames are in points. Applying the device scale as a single
  // root transform means every child, every stroke width and every glyph run
  // is rasterised at device resolution by the same matrix. Scaling per node
  // would compound on nested views and re-round geometry at each level.
  //
  // Save/restore so the builder is handed back in the state it arrived in;
  // callers reuse it for the probe banner, which draws in device pixels.
  const bool scaled = pointScaleFactor != 1.0f && pointScaleFactor > 0.0f;
  if (scaled) {
    ImpellerDisplayListBuilderSave(builder);
    ImpellerDisplayListBuilderScale(builder, pointScaleFactor,
                                    pointScaleFactor);
  }
  // Counts every node actually visited, not the roots and not nodes_.size():
  // a gate needs to tell "walked the tree" from "walked one root that had no
  // reachable children", and those differ by exactly this number.
  painted_ = 0;
  spritesDrawn_ = 0;
  pointScale_ = pointScaleFactor > 0.0f ? pointScaleFactor : 1.0f;  // elevation DPR
  for (auto rootTag : roots_) {
    auto it = nodes_.find(rootTag);
    if (it == nodes_.end()) continue;
    paintNode(builder, it->second, 0, 0);
  }
  if (scaled) ImpellerDisplayListBuilderRestore(builder);
  return painted_;
}

size_t SceneGraph::nodeCount() {
  std::lock_guard<std::mutex> lock(mutex_);
  return nodes_.size();
}

facebook::react::Tag SceneGraph::rootTag() {
  std::lock_guard<std::mutex> lock(mutex_);
  return roots_.empty() ? 0 : roots_.front();
}

// item 11. Tab order.
void SceneGraph::tabOrderWalk(const SceneNode& node,
                              std::vector<facebook::react::Tag>* out) {
  const auto& lm = node.layoutMetrics;
  if (lm.displayType == facebook::react::DisplayType::None) return;
  const bool hasSize = lm.frame.size.width > 0 && lm.frame.size.height > 0;
  if (hasSize) {
    if (node.isTextInput) {
      if (node.tiEditable && node.focusable) out->push_back(node.tag);
    } else if (node.focusable) {
      out->push_back(node.tag);
    }
  }
  if (node.isTextInput) return;  // a field has no focusable children
  for (auto c : node.children) {
    auto it = nodes_.find(c);
    if (it != nodes_.end()) tabOrderWalk(it->second, out);
  }
}

std::vector<facebook::react::Tag> SceneGraph::tabOrder() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::vector<facebook::react::Tag> out;
  for (auto r : roots_) {
    auto it = nodes_.find(r);
    if (it != nodes_.end()) tabOrderWalk(it->second, &out);
  }
  return out;
}

bool SceneGraph::isTextInputTag(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  return it != nodes_.end() && it->second.isTextInput;
}

// ENG-15. See the header.
bool SceneGraph::isSwitchTag(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  return it != nodes_.end() && it->second.isSwitch;
}

int SceneGraph::toggleSwitch(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  if (it == nodes_.end() || !it->second.isSwitch || it->second.swDisabled) return -1;
  it->second.swValue = !it->second.swValue;
  bumpVersion();  // the thumb moves and the track recolours
  return it->second.swValue ? 1 : 0;
}

int SceneGraph::setSwitchValue(facebook::react::Tag tag, bool value) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  if (it == nodes_.end() || !it->second.isSwitch) return -1;
  if (it->second.swValue != value) {
    it->second.swValue = value;
    bumpVersion();
  }
  return value ? 1 : 0;
}

void SceneGraph::setFocusedView(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (focusedView_ == tag) return;
  focusedView_ = tag;
  bumpVersion();  // the focus ring appears / disappears
}

facebook::react::Tag SceneGraph::focusedView() {
  std::lock_guard<std::mutex> lock(mutex_);
  return focusedView_;
}

std::string SceneGraph::frameReport() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::string out;
  char buf[256];
  for (const auto& [tag, node] : nodes_) {
    const auto& f = node.layoutMetrics.frame;
    std::snprintf(buf, sizeof(buf),
                  "rn-impeller: node_frame=%s,%d,%.1f,%.1f,%.1f,%.1f\n",
                  node.componentName.c_str(), (int)tag, (double)f.origin.x,
                  (double)f.origin.y, (double)f.size.width,
                  (double)f.size.height);
    out += buf;
  }
  return out;
}

facebook::react::Tag SceneGraph::hitTestNode(const SceneNode& node,
                                             float originX,
                                             float originY,
                                             float x,
                                             float y) {
  const auto& frame = node.layoutMetrics.frame;
  const float nx = originX + (float)frame.origin.x;
  const float ny = originY + (float)frame.origin.y;
  const float w = (float)frame.size.width;
  const float h = (float)frame.size.height;

  // parity item 9: pointerEvents='none' removes the node AND its subtree.
  if (node.pointerEvents == 1) return 0;
  if (node.backfaceHidden) return 0;

  // parity item 9: a transformed node is HIT where it is PAINTED. paintNode
  // draws it as translate(c) * M * translate(-c) about its centre c; map the
  // point back through the inverse so the rest of this walk (children
  // included) runs in untransformed space, exactly as paint does.
  if (node.hasTransform) {
    const float cx = nx + w * 0.5f, cy = ny + h * 0.5f;
    const auto& m = node.transform;  // column-major 4x4; 2D affine part
    const float a = m[0], b = m[1], cc = m[4], d = m[5], tx = m[12], ty = m[13];
    const float det = a * d - b * cc;
    if (std::fabs(det) < 1e-6f) return 0;  // degenerate (scale 0): unhittable
    const float px = x - cx - tx, py = y - cy - ty;
    x = cx + (d * px - cc * py) / det;
    y = cy + (-b * px + a * py) / det;
  }
  const bool inside = x >= nx && x < nx + w && y >= ny && y < ny + h;

  // A clipping node crops its subtree to its own bounds, so a point outside it
  // cannot hit any descendant either -- bail before recursing. Without this a
  // child scrolled out of view is still hittable, which is the classic
  // "pressed an invisible button" bug. Non-clipping parents must NOT bail:
  // React Native lets children overflow their parent by default, and those
  // children do paint, so they must remain hittable.
  if (node.overflowHidden && !inside) return 0;

  // ⛔ THE SCROLL OFFSET MUST BE APPLIED TO THE CHILD ORIGIN HERE TOO.
  // paintNode shifts a ScrollView's children by -scrollY; if this walk did not,
  // hit testing would use the UNSCROLLED positions and every press after a
  // scroll would land on whichever row used to be there. That bug paints
  // perfectly and logs nothing -- the only symptom is "tapping row 3 opens
  // row 1" -- so the two shifts are deliberately written as the same
  // expression and must be changed together.
  //
  // Reverse paint order: last painted is topmost, so it is tested first.
  const float childOriginY = node.isScrollView ? ny - node.scrollY : ny;
  const float childOriginX = node.isScrollView ? nx - node.scrollX : nx;

  // parity item 9: box-only keeps the node hittable but not its children.
  if (node.pointerEvents != 3) {
    for (auto it = node.children.rbegin(); it != node.children.rend(); ++it) {
      auto child = nodes_.find(*it);
      if (child == nodes_.end()) continue;
      if (auto hit = hitTestNode(child->second, childOriginX, childOriginY, x, y))
        return hit;
    }
  }
  // parity item 9: box-none keeps the children hittable but not the node.
  if (node.pointerEvents == 2) return 0;

  // Zero-sized nodes are never targets. This matters more than it looks: a
  // <Text> whose TextLayoutManager measured 0x0 still PAINTS its glyphs (see
  // frameReport's note), so it would otherwise be visible-but-unhittable ink
  // sitting at a point that reports no hit at all. Excluding it here keeps the
  // hit result honest rather than silently returning a degenerate box.
  if (inside && w > 0.0f && h > 0.0f) return node.tag;
  return 0;
}

facebook::react::Tag SceneGraph::hitTest(float x, float y) {
  std::lock_guard<std::mutex> lock(mutex_);
  // Roots in reverse too: a later root paints over an earlier one.
  for (auto it = roots_.rbegin(); it != roots_.rend(); ++it) {
    auto root = nodes_.find(*it);
    if (root == nodes_.end()) continue;
    if (auto hit = hitTestNode(root->second, 0, 0, x, y)) return hit;
  }
  return 0;
}

facebook::react::EventEmitter::Shared SceneGraph::eventEmitterFor(
    facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  if (it == nodes_.end()) return nullptr;
  return it->second.eventEmitter;
}

int SceneGraph::cursorKindFor(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  // ⛔ THE CURSOR IS AN INHERITED PROPERTY, SO RESOLVE IT FROM THE ANCESTRY,
  // NOT FROM THE HIT LEAF ALONE. hitTest returns the topmost node under the
  // point, which is almost never the node that carried cursor:'pointer': a
  // Pressable wraps a Text or an inner View, and THOSE are what the point
  // lands on. Reading only the leaf's cursorKind therefore reported arrow for
  // every control whose clickable surface has any child — the icon inside a
  // button, the label inside a Pressable — even though the author set the
  // cursor on the wrapper. That is CSS's own rule (cursor inherits, and
  // `cursor:auto` on a child means "ask my ancestors"), and it is what makes
  // "hovering anywhere on a button shows the hand" true.
  //
  // Walk UP from the leaf; the NEAREST explicit (non-arrow) cursor wins, so a
  // Text field (cursor:text) nested inside a card (no cursor) still reads
  // ibeam, and a plain <Text> label inside a Pressable (cursor:pointer) reads
  // hand. A node whose own cursorKind is arrow is treated as "inherit", NOT as
  // an explicit arrow request — Cursor::Auto and Cursor::Default both collapse
  // to 0 at mount (see the switch in applyProps), so there is no explicit
  // arrow to honour here anyway; an author who wants to FORCE arrow inside a
  // hand region is a case RN's three-shape cursor model cannot express and
  // this engine does not claim to. The loop is bounded by the tree depth and
  // guarded against a cycle by the visited-parent check the tree can never
  // actually trip, so a corrupt parent link fails safe to arrow.
  facebook::react::Tag cur = tag;
  while (cur != 0) {
    auto it = nodes_.find(cur);
    if (it == nodes_.end()) break;
    if (it->second.cursorKind != 0) return it->second.cursorKind;  // explicit
    if (it->second.parent == cur) break;  // self-parent: fail safe to arrow
    cur = it->second.parent;
  }
  return 0;  // arrow — no ancestor set an explicit cursor
}

// <TextInput>. ENG-01b. Editing state, all under mutex_ so the paint (which
// reads tiFocused_/tiEditValue_/tiCaret_) never sees a half-applied edit.
void SceneGraph::setTextInputFocus(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  tiFocused_ = tag;
  // Seed the edit buffer from the field's controlled value so a click into an
  // already-populated field edits its existing text rather than blanking it.
  auto it = nodes_.find(tag);
  tiEditValue_ = (it != nodes_.end()) ? it->second.tiValue : std::string();
  tiCaret_ = tiEditValue_.size();
  // item 4a: focusing always starts with a COLLAPSED selection at the caret
  // (focus end == anchor end). Mouse-drag selection (item 4b) is not built
  // yet, so every focus path collapses.
  tiSelAnchor_ = tiCaret_;
  // item 5: focusing a field shows the caret immediately, then blinks from
  // here. Without this reset the caret's phase would be whatever the free clock
  // happened to be at, so a field could focus into an off phase and look dead.
  tiCaretResetAt_ = std::chrono::steady_clock::now();
  tiScrollX_ = tiScrollY_ = 0.0f;  // ENG-24: a new field starts unscrolled
  // P12-01: focus shows the caret + seeds the buffer — scene damage.
  bumpVersion();
}

void SceneGraph::setTextInputEdit(facebook::react::Tag tag,
                                  const std::string& value, size_t caret) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (tiFocused_ != tag) return;  // ignore edits for a field that lost focus
  tiEditValue_ = value;
  tiCaret_ = caret > value.size() ? value.size() : caret;
  // item 4a: EVERY plain edit/caret-move through this entry point COLLAPSES
  // the selection to the new caret. setTextInputSelection (below) is the ONLY
  // entry point that can leave anchor != caret -- see its header.
  tiSelAnchor_ = tiCaret_;
  // item 5: EVERY keystroke re-shows the caret. This is the half a free-running
  // `(now/500)%2` blink gets wrong -- typing during an off phase would land the
  // character next to an invisible caret. Resetting the phase here guarantees
  // the caret is on for the first half-period after any edit.
  tiCaretResetAt_ = std::chrono::steady_clock::now();
  // P12-01: an edit changes the glyphs and the caret index — scene damage.
  bumpVersion();
}

void SceneGraph::setTextInputSelection(facebook::react::Tag tag,
                                       const std::string& value,
                                       size_t anchor, size_t caret) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (tiFocused_ != tag) return;  // ignore edits for a field that lost focus
  tiEditValue_ = value;
  tiCaret_ = caret > value.size() ? value.size() : caret;
  tiSelAnchor_ = anchor > value.size() ? value.size() : anchor;
  tiCaretResetAt_ = std::chrono::steady_clock::now();
  // P12-01: a selection change repaints the highlight rect — scene damage.
  bumpVersion();
}

void SceneGraph::clearTextInputFocus() {
  std::lock_guard<std::mutex> lock(mutex_);
  tiFocused_ = 0;
  tiEditValue_.clear();
  tiCaret_ = 0;
  tiSelAnchor_ = 0;
  tiScrollX_ = tiScrollY_ = 0.0f;  // ENG-24
  // P12-01: blur erases the caret the cached frame still shows — scene damage.
  bumpVersion();
}

facebook::react::Tag SceneGraph::focusedTextInput() {
  std::lock_guard<std::mutex> lock(mutex_);
  return tiFocused_;
}

// desktop-input-gap item 3: click-to-caret.
bool SceneGraph::absoluteOriginLocked(facebook::react::Tag tag, float* ox,
                                      float* oy) {
  float x = 0.0f, y = 0.0f;
  facebook::react::Tag cur = tag;
  bool self = true;
  for (int guard = 0; cur != 0 && guard < 4096; ++guard) {
    auto it = nodes_.find(cur);
    if (it == nodes_.end()) return false;
    const SceneNode& n = it->second;
    // hitTestNode shifts a ScrollView's CHILDREN by -scroll; the ScrollView
    // itself is not shifted. So subtract only for ancestors, never for self.
    if (!self && n.isScrollView) {
      x -= n.scrollX;
      y -= n.scrollY;
    }
    x += (float)n.layoutMetrics.frame.origin.x;
    y += (float)n.layoutMetrics.frame.origin.y;
    self = false;
    if (n.parent == cur) break;
    cur = n.parent;
  }
  *ox = x;
  *oy = y;
  return true;
}

// ENG-24. The TextInput paragraph paintNode draws (face, size, wrap), for
// the click mapping and the content-size report. Caller owns the result and
// holds mutex_. `raw` is the value; a secure field measures its mask.
ImpellerParagraph SceneGraph::buildTextInputParagraphLocked(
    const SceneNode& node, const std::string& raw, float boxW) {
  const std::string shown = node.tiSecure ? SecureMask(raw) : raw;
  return BuildTextInputParagraph(typography_, node, shown, boxW, nullptr);
}

bool SceneGraph::textInputKeyTraits(facebook::react::Tag tag, bool* multiline,
                                    int* submitBehavior) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  if (it == nodes_.end() || !it->second.isTextInput) return false;
  *multiline = it->second.tiMultiline;
  *submitBehavior = it->second.tiSubmitBehavior;
  return true;
}

bool SceneGraph::textInputContentSize(facebook::react::Tag tag, float* outW,
                                      float* outH) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  if (it == nodes_.end() || !it->second.isTextInput || typography_ == nullptr)
    return false;
  const SceneNode& node = it->second;
  const std::string raw = (tiFocused_ == tag) ? tiEditValue_ : node.tiValue;
  const float boxW = node.layoutMetrics.frame.size.width;
  const auto& insets = node.layoutMetrics.contentInsets;
  const float lineH = TextInputLineH(node);  // ENG-23 TextInput
  // A multiline field's content is as wide as its wrap width, empty or not.
  float textW = node.tiMultiline ? TextInputWrapWidth(true, boxW, TextInputPadL(node),
                                            TextInputPadR(node))
                                 : 0.0f;
  float textH = lineH;
  {
    // An empty field is one line tall: measure a one-glyph stand-in so the
    // empty and the one-line heights agree (no jump on the first keystroke).
    const std::string probe = raw.empty() ? std::string("x") : raw;
    ImpellerParagraph par = buildTextInputParagraphLocked(node, probe, boxW);
    if (par == nullptr) return false;
    if (!node.tiMultiline && !raw.empty()) {
      textW = ImpellerParagraphGetMaxIntrinsicWidth(par);
    }
    textH = ImpellerParagraphGetHeight(par);
    if (!raw.empty()) {
      // A trailing newline opens an empty last line the layout may not count.
      const std::string shown = node.tiSecure ? SecureMask(raw) : raw;
      const TiCaret end = TextInputCaretAt(par, shown, shown.size(), lineH);
      textH = std::max(textH, end.y + end.h);
    }
    ImpellerParagraphRelease(par);
  }
  // iOS reports the text view's content: the text plus its padding (RN sets
  // the text container inset to contentInsets minus the border).
  const float* bw = node.borderWidths;  // top, right, bottom, left
  *outW = textW + std::max(0.0f, (float)insets.left - bw[3]) +
          std::max(0.0f, (float)insets.right - bw[1]);
  *outH = textH + std::max(0.0f, (float)insets.top - bw[0]) +
          std::max(0.0f, (float)insets.bottom - bw[2]);
  return true;
}

bool SceneGraph::glyphBoundariesLocked(facebook::react::Tag tag,
                                       std::vector<size_t>* offsets,
                                       std::vector<float>* xs) {
  offsets->clear();
  xs->clear();
  auto it = nodes_.find(tag);
  if (it == nodes_.end() || !it->second.isTextInput || typography_ == nullptr)
    return false;
  const SceneNode& node = it->second;
  float ox = 0.0f, oy = 0.0f;
  if (!absoluteOriginLocked(tag, &ox, &oy)) return false;
  const std::string raw = (tiFocused_ == tag) ? tiEditValue_ : node.tiValue;
  // Style audit item 11: a secure field's glyphs are bullets, so its click
  // boundaries are measured over the mask. Boundaries are reported in SOURCE
  // byte offsets (one bullet per source codepoint), which the caret uses.
  const std::string shown = rni::applyTextTransform(
      node.tiSecure ? SecureMask(raw) : raw, node.tiFace.transform);  // SC-20
  // ENG-24: a focused single-line field may be scrolled sideways.
  const float alignDx = TextInputAlignDx(
      typography_, node, shown.empty() ? node.tiPlaceholder : shown,
      (float)node.layoutMetrics.frame.size.width);
  const float textX = ox + TextInputPadL(node) + alignDx -
                      ((tiFocused_ == tag && !node.tiMultiline) ? tiScrollX_ : 0.0f);
  // Boundary 0 is the text start. Then one boundary after every codepoint
  // (a UTF-8 lead byte is any byte that is not 10xxxxxx).
  offsets->push_back(0);
  xs->push_back(textX);
  ImpellerParagraphStyle style = ImpellerParagraphStyleNew();
  ImpellerParagraphStyleSetFontSize(style, node.fontSize);
  // ENG-22: a click must map through the SAME face the glyphs painted in.
  ApplyFontFamily(style, node.fontFamily);
  rni::ApplyTextInputFace(style, node.tiFace, false);  // SC-20
  for (size_t i = 1; i <= raw.size(); ++i) {
    if (i < raw.size() && (((unsigned char)raw[i]) & 0xC0) == 0x80) continue;
    const size_t mi = node.tiSecure ? SecureMaskOffset(raw, i) : i;
    ImpellerParagraphBuilder pb = ImpellerParagraphBuilderNew(typography_);
    ImpellerParagraphBuilderPushStyle(pb, style);
    ImpellerParagraphBuilderAddText(pb, (const uint8_t*)shown.data(), mi);
    ImpellerParagraph par = ImpellerParagraphBuilderBuildParagraphNew(pb, 1e6f);
    float wpx = 0.0f;
    if (par != nullptr) {
      wpx = ImpellerParagraphGetMaxIntrinsicWidth(par);
      ImpellerParagraphRelease(par);
    }
    ImpellerParagraphBuilderRelease(pb);
    offsets->push_back(i);
    xs->push_back(textX + wpx);
  }
  ImpellerParagraphStyleRelease(style);
  return true;
}

size_t SceneGraph::caretIndexForClick(facebook::react::Tag tag, float screenX,
                                      float screenY) {
  std::lock_guard<std::mutex> lock(mutex_);
  // ENG-25: a MULTILINE field maps the click through the wrapped layout the
  // painter draws: the line under `screenY` first, then the nearest
  // boundary on that line. A press above the text lands on line 1, below it
  // on the last line.
  {
    auto it = nodes_.find(tag);
    float ox = 0.0f, oy = 0.0f;
    if (it != nodes_.end() && it->second.isTextInput && it->second.tiMultiline &&
        typography_ != nullptr && absoluteOriginLocked(tag, &ox, &oy)) {
      const std::string raw = (tiFocused_ == tag) ? tiEditValue_ : it->second.tiValue;
      TiGeom g;
      TiGeomOf(typography_, it->second, raw, ox, oy,
               (tiFocused_ == tag) ? tiScrollY_ : 0.0f, &g);
      size_t L = g.lines.size() - 1;
      for (size_t i = 0; i < g.lines.size(); ++i) {
        if (screenY < g.textY + g.lines[i].top + g.lines[i].height) {
          L = i;
          break;
        }
      }
      return g.offsets[TiNearestOnLine(g, L, screenX)];
    }
  }
  std::vector<size_t> offsets;
  std::vector<float> xs;
  if (!glyphBoundariesLocked(tag, &offsets, &xs) || offsets.empty()) return 0;
  // Nearest boundary: a click on the left half of a glyph lands before it,
  // on the right half after it. Past-end clamps to the end, before-start to 0.
  size_t best = 0;
  float bestD = std::fabs(screenX - xs[0]);
  for (size_t i = 1; i < xs.size(); ++i) {
    const float d = std::fabs(screenX - xs[i]);
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return offsets[best];
}

std::string SceneGraph::glyphBoundaryReportFor(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  std::vector<size_t> offsets;
  std::vector<float> xs;
  // ENG-25: a multiline field reports its WRAPPED boundaries (the ones a
  // click maps through), plus a second line naming each boundary's line and
  // each line's screen top.
  std::string lineReport;
  {
    auto it = nodes_.find(tag);
    float ox = 0.0f, oy = 0.0f;
    if (it != nodes_.end() && it->second.isTextInput && it->second.tiMultiline &&
        typography_ != nullptr && absoluteOriginLocked(tag, &ox, &oy)) {
      const std::string raw = (tiFocused_ == tag) ? tiEditValue_ : it->second.tiValue;
      TiGeom g;
      TiGeomOf(typography_, it->second, raw, ox, oy,
               (tiFocused_ == tag) ? tiScrollY_ : 0.0f, &g);
      xs = g.xs;
      lineReport = "\nrn-impeller: ti_glyph_lines tag=" + std::to_string((int)tag) +
                   " line=";
      for (size_t i = 0; i < g.line.size(); ++i) {
        lineReport += (i ? "," : "") + std::to_string(g.line[i]);
      }
      lineReport += " tops=";
      char tb[32];
      for (size_t i = 0; i < g.lines.size(); ++i) {
        snprintf(tb, sizeof(tb), "%s%.2f", i ? "," : "", g.textY + g.lines[i].top);
        lineReport += tb;
      }
    } else if (!glyphBoundariesLocked(tag, &offsets, &xs)) {
      return std::string();
    }
  }
  std::string out = "rn-impeller: ti_glyph_x tag=" + std::to_string((int)tag) +
                    " xs=";
  char buf[32];
  for (size_t i = 0; i < xs.size(); ++i) {
    snprintf(buf, sizeof(buf), "%s%.2f", i ? "," : "", xs[i]);
    out += buf;
  }
  return out + lineReport;
}

// ENG-25.
bool SceneGraph::isMultilineTextInput(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  return it != nodes_.end() && it->second.isTextInput && it->second.tiMultiline;
}

// ENG-25. Up/Down in a multiline field, through the wrapped layout: the
// boundary on the line above/below nearest the goal x. Up on the first line
// goes to the start, Down on the last line to the end (NSTextView). `goalX`
// in: the x to aim at (< 0 = the caret's own x); out: the x aimed at, so a
// run of Up/Down keeps its column across shorter lines.
size_t SceneGraph::textInputVerticalMove(facebook::react::Tag tag, size_t caret,
                                         int dir, float* goalX) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  float ox = 0.0f, oy = 0.0f;
  if (it == nodes_.end() || !it->second.isTextInput || !it->second.tiMultiline ||
      typography_ == nullptr || !absoluteOriginLocked(tag, &ox, &oy)) {
    return caret;
  }
  const std::string raw = (tiFocused_ == tag) ? tiEditValue_ : it->second.tiValue;
  TiGeom g;
  TiGeomOf(typography_, it->second, raw, ox, oy,
               (tiFocused_ == tag) ? tiScrollY_ : 0.0f, &g);
  size_t cur = 0;
  for (size_t i = 0; i < g.offsets.size(); ++i) {
    if (g.offsets[i] <= caret) cur = i;
  }
  const float x = (goalX != nullptr && *goalX >= 0.0f) ? *goalX : g.xs[cur];
  if (goalX != nullptr) *goalX = x;
  const size_t L = g.line[cur];
  if (dir < 0 && L == 0) return 0;
  if (dir > 0 && L + 1 >= g.lines.size()) return raw.size();
  return g.offsets[TiNearestOnLine(g, dir < 0 ? L - 1 : L + 1, x)];
}

bool SceneGraph::isSecureTextInput(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  return it != nodes_.end() && it->second.tiSecure;
}

std::string SceneGraph::textInputValueFor(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (tiFocused_ == tag) return tiEditValue_;
  auto it = nodes_.find(tag);
  return (it != nodes_.end()) ? it->second.tiValue : std::string();
}

size_t SceneGraph::textInputCaretFor(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  return (tiFocused_ == tag) ? tiCaret_ : 0;
}

size_t SceneGraph::textInputSelectionAnchorFor(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  return (tiFocused_ == tag) ? tiSelAnchor_ : 0;
}

std::string SceneGraph::paragraphTextReport() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::string out;
  for (const auto& [tag, node] : nodes_) {
    if (node.isParagraph) {
      out += "rn-impeller: paragraph_text tag=" + std::to_string((int)tag) +
             " \"" + node.text + "\"\n";
    }
  }
  return out;
}

// P1 item 15. The hit walk resolves the DEEPEST node with a frame under the
// point; a selectable <Text> is a leaf Paragraph (its nested runs are
// fragments, not nodes), so a direct hit on it is exactly "the press is on
// this text". Its own pointerEvents/clip/scroll rules come from hitTestNode.
facebook::react::Tag SceneGraph::selectableTextAt(float x, float y) {
  std::lock_guard<std::mutex> lock(mutex_);
  for (auto it = roots_.rbegin(); it != roots_.rend(); ++it) {
    auto root = nodes_.find(*it);
    if (root == nodes_.end()) continue;
    if (auto hit = hitTestNode(root->second, 0, 0, x, y)) {
      auto n = nodes_.find(hit);
      if (n != nodes_.end() && n->second.isParagraph && n->second.selectable &&
          !n->second.runs.empty()) {
        return hit;
      }
      return 0;
    }
  }
  return 0;
}

size_t SceneGraph::textOffsetAt(facebook::react::Tag tag, float x, float y) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  if (it == nodes_.end() || !it->second.isParagraph) return 0;
  const SceneNode& node = it->second;
  float ox = 0.0f, oy = 0.0f;
  if (!absoluteOriginLocked(tag, &ox, &oy)) return 0;
  const std::string shown = JoinRuns(node);
  const auto& cin = node.layoutMetrics.contentInsets;
  ox += (float)cin.left;
  oy += (float)cin.top;
  ImpellerParagraph par = buildRunParagraph(
      node, std::max(0.0f, (float)node.layoutMetrics.frame.size.width -
                               (float)(cin.left + cin.right)));
  if (par == nullptr) return 0;
  size_t off = 0;
  oy += ParagraphVOffset(node, par, (float)node.layoutMetrics.frame.size.height -
                                        (float)(cin.top + cin.bottom));
  ImpellerGlyphInfo gi = ImpellerParagraphCreateGlyphInfoAtParagraphCoordinatesNew(
      par, (double)(x - ox), (double)(y - oy));
  if (gi != nullptr) {
    // Nearer edge of the cluster under the point: a press on the right half
    // of a glyph puts the boundary AFTER it, the way every text view does.
    const ImpellerRect r = ClusterBounds(gi);
    const size_t b = ImpellerGlyphInfoGetGraphemeClusterCodeUnitRangeBegin(gi);
    const size_t e = ImpellerGlyphInfoGetGraphemeClusterCodeUnitRangeEnd(gi);
    const bool after = (x - ox) > r.x + r.width * 0.5f;
    off = Utf16ToUtf8Index(shown, after ? e : b);
    ImpellerGlyphInfoRelease(gi);
  } else if ((x - ox) > 0.0f) {
    off = shown.size();  // past the last glyph
  }
  ImpellerParagraphRelease(par);
  return off;
}

void SceneGraph::setTextSelection(facebook::react::Tag tag, size_t anchor,
                                  size_t caret) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (tag == textSelTag_ && anchor == textSelAnchor_ && caret == textSelCaret_) return;
  textSelTag_ = tag;
  textSelAnchor_ = anchor;
  textSelCaret_ = caret;
  // P12-01: the highlight moved -- scene damage, or an idle window never
  // repaints it (the same rule setTextInputSelection follows).
  bumpVersion();
}

void SceneGraph::clearTextSelection() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (textSelTag_ == 0 && textSelAnchor_ == textSelCaret_) return;
  textSelTag_ = 0;
  textSelAnchor_ = textSelCaret_ = 0;
  bumpVersion();  // P12-01: the highlight disappears
}

facebook::react::Tag SceneGraph::textSelectionTag() {
  std::lock_guard<std::mutex> lock(mutex_);
  return textSelAnchor_ != textSelCaret_ ? textSelTag_ : 0;
}

std::string SceneGraph::selectableTextFor(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  return it == nodes_.end() ? std::string() : JoinRuns(it->second);
}

std::string SceneGraph::selectedText() {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(textSelTag_);
  if (it == nodes_.end() || textSelAnchor_ == textSelCaret_) return {};
  const std::string shown = JoinRuns(it->second);
  const size_t lo = std::min(std::min(textSelAnchor_, textSelCaret_), shown.size());
  const size_t hi = std::min(std::max(textSelAnchor_, textSelCaret_), shown.size());
  return shown.substr(lo, hi - lo);
}

std::string SceneGraph::describe() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::string out;
  char buf[256];
  std::snprintf(buf, sizeof(buf), "nodes=%zu roots=%zu", nodes_.size(),
                roots_.size());
  out = buf;
  for (const auto& [tag, node] : nodes_) {
    const auto& f = node.layoutMetrics.frame;
    std::snprintf(buf, sizeof(buf), " | %s#%d {%.0f,%.0f %.0fx%.0f}%s",
                  node.componentName.c_str(), tag, (double)f.origin.x,
                  (double)f.origin.y, (double)f.size.width,
                  (double)f.size.height,
                  node.hasBackgroundColor ? " bg" : "");
    out += buf;
  }
  return out;
}

// <ScrollView>. ENG-02.
//
// Walks UP from whatever the point hit, rather than down looking for a
// ScrollView. A wheel over a row must scroll the list that contains the row,
// and the row is what hitTest resolves -- searching downward would find the
// ScrollView only when the pointer happened to be over its background, i.e.
// only on an empty list.
facebook::react::Tag SceneGraph::scrollViewAt(float x, float y) {
  std::lock_guard<std::mutex> lock(mutex_);
  facebook::react::Tag hit = 0;
  for (auto it = roots_.rbegin(); it != roots_.rend(); ++it) {
    auto root = nodes_.find(*it);
    if (root == nodes_.end()) continue;
    if ((hit = hitTestNode(root->second, 0, 0, x, y))) break;
  }
  if (hit == 0) return 0;

  // Bounded: a corrupt parent chain that formed a cycle would hang the event
  // thread, which is worse than missing a scroll.
  int guard = 0;
  facebook::react::Tag cur = hit;
  while (cur != 0 && guard++ < 256) {
    auto it = nodes_.find(cur);
    if (it == nodes_.end()) return 0;
    if (it->second.isScrollView) return cur;
    cur = it->second.parent;
  }
  return 0;
}

// <ScrollView>. ENG-02c NESTED.
//
// ⛔ THE AXIS PICKS THE VIEW, THE VIEW DOES NOT PICK THE AXIS.
//
// ENG-02/02b resolved ONE ScrollView (the nearest ancestor of the hit) and
// then derived which axis of THAT view to move. Nested lists break that order:
// over a horizontal row inside a vertical list, the nearest ScrollView is the
// inner list, so a dx wheel -- which the row is the only thing that can consume
// -- was handed to the inner list, whose X does not overflow, and dropped. The
// outer row never moved and the gesture read as "sideways scroll is dead".
//
// The fix is to decide the wheel AXIS FIRST (from the delta the host sent) and
// then walk up for the nearest ancestor that actually overflows on THAT axis.
// A dx finds the row; a dy at the same point finds the inner list; each leaves
// the other exactly where it was. This is per-axis RESOLUTION, distinct from
// the per-axis derivation ENG-02b already does for a single view.
//
// Content extent per node is the UNION of every child (origin + size), for the
// reason documented at ENG-02: fixtures/p9-scroll's ScrollView has a sized
// viewport child AND a taller content container, and front() picked the wrong
// one, clamping every scroll to zero. Read live, not from a paint cache, so a
// headless run that never painted still scrolls.
SceneGraph::ScrollResult SceneGraph::scrollTo(facebook::react::Tag tag,
                                             float x, float y, bool toEnd) {
  ScrollResult r{};
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  if (it == nodes_.end() || !it->second.isScrollView) return r;
  SceneNode& sv = it->second;
  // Same extent rule as scrollBy: union of the children's frames minus the
  // viewport, per axis.
  float contentW = 0.0f, contentH = 0.0f;
  for (auto childTag : sv.children) {
    auto content = nodes_.find(childTag);
    if (content == nodes_.end()) continue;
    const auto& cf = content->second.layoutMetrics.frame;
    contentW = std::max(contentW, (float)(cf.origin.x + cf.size.width));
    contentH = std::max(contentH, (float)(cf.origin.y + cf.size.height));
  }
  const float containerW = (float)sv.layoutMetrics.frame.size.width;
  const float containerH = (float)sv.layoutMetrics.frame.size.height;
  const float maxX = std::max(0.0f, contentW - containerW);
  const float maxY = std::max(0.0f, contentH - containerH);
  const float beforeX = sv.scrollX;
  const float beforeY = sv.scrollY;
  if (toEnd) {
    // scrollToEnd: the end of whichever axis overflows (vertical wins a tie,
    // matching RN iOS, which picks horizontal only for a horizontal list).
    if (maxY > 0.0f || maxX <= 0.0f) {
      sv.scrollY = maxY;
    } else {
      sv.scrollX = maxX;
    }
  } else {
    sv.scrollX = std::min(std::max(0.0f, x), maxX);
    sv.scrollY = std::min(std::max(0.0f, y), maxY);
  }
  r.tag = tag;
  r.offsetX = sv.scrollX;
  r.offsetY = sv.scrollY;
  r.contentWidth = contentW;
  r.contentHeight = contentH;
  r.containerWidth = containerW;
  r.containerHeight = containerH;
  r.moved = (sv.scrollX != beforeX) || (sv.scrollY != beforeY);
  if (r.moved) bumpVersion();
  return r;
}

void SceneGraph::setTextInputValue(facebook::react::Tag tag,
                                   const std::string& value) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  if (it == nodes_.end() || !it->second.isTextInput) return;
  it->second.tiValue = value;
  bumpVersion();
}

SceneGraph::ScrollResult SceneGraph::scrollBy(float x, float y, float dx,
                                             float dy) {
  ScrollResult r{};

  std::lock_guard<std::mutex> lock(mutex_);

  // The hit target, in the same POINT space as scrollViewAt. Inlined here (not
  // via scrollViewAt) because that helper takes the lock itself AND stops at
  // the first ScrollView -- nested resolution has to keep walking past it.
  facebook::react::Tag hit = 0;
  for (auto rit = roots_.rbegin(); rit != roots_.rend(); ++rit) {
    auto root = nodes_.find(*rit);
    if (root == nodes_.end()) continue;
    if ((hit = hitTestNode(root->second, 0, 0, x, y))) break;
  }
  if (hit == 0) return r;

  // ⛔ AXIS FROM THE DELTA THE HOST SENT, NOT FROM ANY VIEW'S CONTENT.
  //
  // A wheel/trackpad notch is one-dimensional per event; the host forwards it
  // as (dx,dy) with the unused axis zero. The dominant magnitude is the axis
  // the user meant. A tie (both zero, or a genuine diagonal the host never
  // actually sends) falls back to Y, matching a mouse wheel's default axis and
  // keeping a degenerate 0,0 event a no-op rather than an accidental X move.
  const bool wheelHorizontal = std::abs(dx) > std::abs(dy);

  // Extent of one ScrollView node: union content box minus its viewport, per
  // axis. Returns the max scrollable offset on each axis (0 == does not
  // overflow that way).
  struct Extent {
    float contentW, contentH, containerW, containerH, maxX, maxY;
  };
  auto extentOf = [&](const SceneNode& sv) -> Extent {
    float contentW = 0.0f, contentH = 0.0f;
    for (auto childTag : sv.children) {
      auto content = nodes_.find(childTag);
      if (content == nodes_.end()) continue;
      const auto& cf = content->second.layoutMetrics.frame;
      contentW = std::max(contentW, (float)(cf.origin.x + cf.size.width));
      contentH = std::max(contentH, (float)(cf.origin.y + cf.size.height));
    }
    const float containerW = (float)sv.layoutMetrics.frame.size.width;
    const float containerH = (float)sv.layoutMetrics.frame.size.height;
    return {contentW, contentH, containerW, containerH,
            std::max(0.0f, contentW - containerW),
            std::max(0.0f, contentH - containerH)};
  };

  // Walk UP from the hit. Choose the NEAREST ancestor that overflows on the
  // wheel axis. Remember the nearest ScrollView of ANY kind as a fallback for
  // the degenerate case where nothing overflows the chosen axis (e.g. a
  // fully-scrolled list) -- clamping there is still correct and keeps the
  // event owned by a real scroll view instead of leaking to its parent.
  //
  // Bounded against a cycle in the parent chain: hanging the event thread is
  // worse than missing one scroll.
  facebook::react::Tag chosen = 0;
  facebook::react::Tag fallback = 0;
  int guard = 0;
  facebook::react::Tag cur = hit;
  while (cur != 0 && guard++ < 256) {
    auto nit = nodes_.find(cur);
    if (nit == nodes_.end()) break;
    const SceneNode& node = nit->second;
    if (node.isScrollView) {
      if (fallback == 0) fallback = cur;
      const Extent e = extentOf(node);
      const float axisMax = wheelHorizontal ? e.maxX : e.maxY;
      if (axisMax > 0.0f) {
        chosen = cur;
        break;
      }
    }
    cur = node.parent;
  }

  const facebook::react::Tag tag = chosen ? chosen : fallback;
  if (tag == 0) return r;

  auto it = nodes_.find(tag);
  if (it == nodes_.end()) return r;
  SceneNode& sv = it->second;
  const Extent e = extentOf(sv);

  // Route the delta through the wheel axis for THIS view. On a horizontal row a
  // dy is a no-op (it never reached here as the chosen axis unless the row was
  // the only fallback, in which case maxY==0 clamps it away), and vice versa --
  // no diagonal drift.
  const float beforeX = sv.scrollX;
  const float beforeY = sv.scrollY;
  if (wheelHorizontal) {
    float next = sv.scrollX + dx;
    if (next < 0.0f) next = 0.0f;
    if (next > e.maxX) next = e.maxX;
    sv.scrollX = next;
  } else {
    float next = sv.scrollY + dy;
    if (next < 0.0f) next = 0.0f;
    if (next > e.maxY) next = e.maxY;
    sv.scrollY = next;
  }

  r.tag = tag;
  r.offsetX = sv.scrollX;
  r.offsetY = sv.scrollY;
  r.contentWidth = e.contentW;
  r.contentHeight = e.contentH;
  r.containerWidth = e.containerW;
  r.containerHeight = e.containerH;
  r.moved = (sv.scrollX != beforeX) || (sv.scrollY != beforeY);
  // P12-01: a scroll that actually moved is scene damage; a clamped no-op at a
  // bound is not, so a wheel against the end of a list does not force a repaint.
  if (r.moved) bumpVersion();
  return r;
}

}  // namespace rni
