#include "scenegraph/SceneGraph.h"

#include "scenegraph/CaretBlink.h"

#include <react/renderer/core/ConcreteState.h>
#include <react/renderer/components/textinput/BaseTextInputProps.h>
#include <react/renderer/graphics/BackgroundImage.h>
#include <react/renderer/graphics/Color.h>
#include <react/renderer/graphics/LinearGradient.h>
#include <react/renderer/graphics/Transform.h>

#if RNI_WITH_RNSVG
#include <react/renderer/components/rnsvg/Props.h>
#include "svg/SvgPath.h"
#endif

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
    for (int i = 0; i < 4; ++i) {
      node.borderWidths[i] = (float)widths[i];
      node.hasBorderColors[i] = (bool)colors[i];
      if (colors[i]) colorToFloats(colors[i], node.borderColors[i]);
    }

    // Radii in IMPELLER's field order (TL, BL, TR, BR), which is NOT the order
    // RN stores them in and NOT clockwise. Getting this wrong rounds the wrong
    // corners while still producing a rounded-looking box.
    node.borderRadii[0] = (float)metrics.borderRadii.topLeft.horizontal;
    node.borderRadii[1] = (float)metrics.borderRadii.bottomLeft.horizontal;
    node.borderRadii[2] = (float)metrics.borderRadii.topRight.horizontal;
    node.borderRadii[3] = (float)metrics.borderRadii.bottomRight.horizontal;

    node.overflowHidden = props->getClipsContentToBounds();

    // ENG-09 hover/cursor. Collapse RN's full Cursor enum to the three shapes
    // the host has standard GLFW cursors for. Everything that is not an
    // explicit pointer/text request reads as arrow -- including Cursor::Auto,
    // which is the default and means "let the platform decide", and the
    // platform decision here is the arrow. Only the two authors actually set
    // to change the pointer are honoured, so a view with no cursor prop (every
    // existing app) is unchanged.
    switch (props->cursor) {
      case react::Cursor::Pointer:
        node.cursorKind = 1;  // hand
        break;
      case react::Cursor::Text:
        node.cursorKind = 2;  // ibeam
        break;
      case react::Cursor::Grab:
        node.cursorKind = 3;  // open hand (NSCursor openHandCursor)
        break;
      case react::Cursor::Grabbing:
        node.cursorKind = 4;  // closed hand (NSCursor closedHandCursor)
        break;
      default:
        node.cursorKind = 0;  // arrow
        break;
    }

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
    node.hasTransform = false;
    if (!props->transform.operations.empty()) {
      const auto resolved = props->resolveTransform(view.layoutMetrics);
      node.transform = resolved.matrix;
      node.hasTransform = resolved != react::Transform::Identity();
    }

    // LINEAR GRADIENT (`experimental_backgroundImage`).
    node.hasGradient = false;
    node.gradStops.clear();
    node.gradColors.clear();
    const float fw = (float)view.layoutMetrics.frame.size.width;
    const float fh = (float)view.layoutMetrics.frame.size.height;
    for (const auto& image : props->backgroundImage) {
      if (!std::holds_alternative<react::LinearGradient>(image)) continue;
      const auto& lg = std::get<react::LinearGradient>(image);
      if (lg.colorStops.size() < 2) continue;

      // Direction -> a start/end point pair on the node's own box. RN gives
      // either a CSS angle (0deg = to top, growing clockwise) or a corner
      // keyword; both reduce to a line through the box centre.
      float angleRad = 0.0f;
      if (std::holds_alternative<react::Float>(lg.direction)) {
        angleRad = (float)std::get<react::Float>(lg.direction) *
                   (float)M_PI / 180.0f;
      } else {
        switch (std::get<react::GradientKeyword>(lg.direction)) {
          case react::GradientKeyword::ToTopRight:    angleRad = 0.25f * (float)M_PI; break;
          case react::GradientKeyword::ToBottomRight: angleRad = 0.75f * (float)M_PI; break;
          case react::GradientKeyword::ToBottomLeft:  angleRad = 1.25f * (float)M_PI; break;
          case react::GradientKeyword::ToTopLeft:     angleRad = 1.75f * (float)M_PI; break;
        }
      }
      // CSS: the gradient line runs through the centre at `angle`, and its ends
      // sit where the box's projection onto that line ends. y is negated
      // because CSS angles measure from "up" while our y axis grows downward.
      const float dx = std::sin(angleRad);
      const float dy = -std::cos(angleRad);
      const float half = (std::fabs(fw * dx) + std::fabs(fh * dy)) * 0.5f;
      const float cx = fw * 0.5f, cy = fh * 0.5f;
      node.gradStart[0] = cx - dx * half;
      node.gradStart[1] = cy - dy * half;
      node.gradEnd[0] = cx + dx * half;
      node.gradEnd[1] = cy + dy * half;

      // Stops. RN leaves `position` unset for stops the author did not place,
      // meaning "distribute evenly" — reading .value blindly makes every such
      // stop 0 and collapses the gradient into a hard edge at the origin.
      const size_t n = lg.colorStops.size();
      for (size_t i = 0; i < n; ++i) {
        const auto& stop = lg.colorStops[i];
        // ValueUnit has an operator bool() that is true only when the unit is
        // set; there is no isDefined(). A percent stop resolves against 1.0
        // because Impeller wants stops as a 0..1 fraction, and
        // ValueUnit::resolve multiplies percent by referenceLength * 0.01.
        float pos = (bool)stop.position
                        ? stop.position.resolve(1.0f)
                        : (float)i / (float)(n - 1);
        float rgba[4] = {0, 0, 0, 0};
        if (stop.color) colorToFloats(stop.color, rgba);
        node.gradStops.push_back(std::clamp(pos, 0.0f, 1.0f));
        node.gradColors.push_back({rgba[0], rgba[1], rgba[2], rgba[3]});
      }
      node.hasGradient = node.gradStops.size() >= 2;
      break;  // first gradient wins; layered backgrounds are a later phase
    }
  }

  // <Text>: the measured AttributedString rides on ParagraphState, which is
  // exactly what Fabric measured with. Painting from the props instead would
  // let measure and paint disagree.
  if (node.componentName == "Paragraph") {
    node.isParagraph = true;
    node.text.clear();
    node.maxLines = 0;
    node.ellipsizeMode = 0;
    node.textTransform = 0;
    if (const auto* pp =
            dynamic_cast<const react::ParagraphProps*>(view.props.get())) {
      node.maxLines = pp->paragraphAttributes.maximumNumberOfLines;
      // ellipsizeMode is only consulted when the paragraph is line-clamped; an
      // unclamped Text never truncates, so the mode is irrelevant there.
      node.ellipsizeMode = (int)pp->paragraphAttributes.ellipsizeMode;
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
      for (const auto& fragment : stateData.attributedString.getFragments()) {
        node.text += fragment.string;
        if (fragment.textAttributes.fontSize > 0) {
          node.fontSize = (float)fragment.textAttributes.fontSize;
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
      const auto attrs = tp->getEffectiveTextAttributes(1.0f);
      if (attrs.fontSize > 0) node.fontSize = (float)attrs.fontSize;
      if (attrs.foregroundColor) {
        colorToFloats(attrs.foregroundColor, node.textColor);
      }
      if (tp->placeholderTextColor) {
        colorToFloats(tp->placeholderTextColor, node.tiPlaceholderColor);
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
  return true;
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
#endif
  ImpellerPaint paint = ImpellerPaintNew();
  ImpellerRect rect = {x, y, w, h};  // {x,y,w,h}, NOT LTRB

  // TRANSFORM. Pushed as translate(origin) * M * translate(-origin) so the
  // matrix RN resolved (which is expressed about the node's own box) applies at
  // the node's painted position. Everything the node draws — background,
  // borders, text, children — is inside this save, because a transform that
  // moved only the background would be a subtler wrong than no transform.
  const bool transformed = node.hasTransform;
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
  radii.top_left = {node.borderRadii[0], node.borderRadii[0]};
  radii.bottom_left = {node.borderRadii[1], node.borderRadii[1]};
  radii.top_right = {node.borderRadii[2], node.borderRadii[2]};
  radii.bottom_right = {node.borderRadii[3], node.borderRadii[3]};
  const bool rounded = node.borderRadii[0] > 0.0f || node.borderRadii[1] > 0.0f ||
                       node.borderRadii[2] > 0.0f || node.borderRadii[3] > 0.0f;

  auto fillBox = [&]() {
    if (rounded) {
      ImpellerDisplayListBuilderDrawRoundedRect(builder, &rect, &radii, paint);
    } else {
      ImpellerDisplayListBuilderDrawRect(builder, &rect, paint);
    }
  };

  // GRADIENT first: in CSS a background image paints over the background colour.
  if (node.hasGradient) {
    std::vector<ImpellerColor> colors;
    colors.reserve(node.gradColors.size());
    for (const auto& c : node.gradColors) {
      colors.push_back(impellerColor(c.data(), node.opacity));
    }
    // Gradient endpoints are stored node-local; the display list is in surface
    // coordinates, so they translate by the node's painted origin.
    ImpellerPoint start = {x + node.gradStart[0], y + node.gradStart[1]};
    ImpellerPoint end = {x + node.gradEnd[0], y + node.gradEnd[1]};
    ImpellerColorSource src = ImpellerColorSourceCreateLinearGradientNew(
        &start, &end, (uint32_t)colors.size(), colors.data(),
        node.gradStops.data(), kImpellerTileModeClamp, nullptr);
    if (src != nullptr) {
      // ⛔ Its OWN paint, not the shared one. `ImpellerPaintSetColorSource` is
      // declared IMPELLER_NONNULL, so there is no way to CLEAR a colour source
      // once set — passing nullptr to unset it segfaults inside Impeller. A
      // paint that has ever held a gradient therefore paints everything after
      // it with that gradient, so the gradient gets a paint that is discarded.
      ImpellerPaint gp = ImpellerPaintNew();
      ImpellerPaintSetColorSource(gp, src);
      if (rounded) {
        ImpellerDisplayListBuilderDrawRoundedRect(builder, &rect, &radii, gp);
      } else {
        ImpellerDisplayListBuilderDrawRect(builder, &rect, gp);
      }
      ImpellerPaintRelease(gp);
      ImpellerColorSourceRelease(src);
    }
  } else if (node.hasBackgroundColor && node.bg[3] > 0.0f) {
    ImpellerColor c = impellerColor(node.bg, node.opacity);
    ImpellerPaintSetColor(paint, &c);
    fillBox();
  }

  paintBorders(builder, node, x, y, w, h, radii, rounded);

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
          const float nodeAlpha = std::clamp(node.opacity, 0.0f, 1.0f);
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
            ImpellerDisplayListBuilderDrawPath(builder, path, strokePaint);
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

  if (node.isParagraph && !node.text.empty() && typography_ != nullptr) {
    ImpellerParagraphStyle style = ImpellerParagraphStyleNew();
    ImpellerParagraphStyleSetFontSize(style, node.fontSize);
    if (node.maxLines > 0) {
      // Painting must honour the same clamp measurement did, or a
      // numberOfLines={1} label is measured at one line and painted at three,
      // overflowing whatever sits below it.
      ImpellerParagraphStyleSetMaxLines(style, (uint32_t)node.maxLines);
      // ⛔ ELLIPSIS ONLY MAKES SENSE ON A CLAMPED PARAGRAPH.
      // ellipsizeMode without maxLines is meaningless — an unclamped paragraph
      // wraps forever and never truncates — so the setter is scoped inside the
      // maxLines guard. RN's EllipsizeMode: 0 Clip (hard cut, NO ellipsis
      // string), 1 Head, 2 Tail (RN default), 3 Middle. Impeller's C API exposes
      // one ellipsis STRING, not a position, so Head/Tail/Middle all set "…" and
      // the engine truncates at the tail; Clip passes nullptr for a hard cut.
      // This is the real ImpellerParagraphStyleSetEllipsis setter (impeller.h
      // :2585) — no manual U+2026 append needed.
      if (node.ellipsizeMode != 0) {
        ImpellerParagraphStyleSetEllipsis(style, "\xE2\x80\xA6");  // U+2026 …
      }
    }
    ImpellerPaint textPaint = ImpellerPaintNew();
    ImpellerColor tc = impellerColor(node.textColor, node.opacity);
    ImpellerPaintSetColor(textPaint, &tc);
    ImpellerParagraphStyleSetForeground(style, textPaint);

    ImpellerParagraphBuilder pb = ImpellerParagraphBuilderNew(typography_);
    ImpellerParagraphBuilderPushStyle(pb, style);
    ImpellerParagraphBuilderAddText(pb, (const uint8_t*)node.text.c_str(),
                                    node.text.size());
    ImpellerParagraph paragraph =
        ImpellerParagraphBuilderBuildParagraphNew(pb, w > 0 ? w : 1e6f);
    if (paragraph != nullptr) {
      ImpellerPoint at = {x, y};
      ImpellerDisplayListBuilderDrawParagraph(builder, paragraph, &at);
      ImpellerParagraphRelease(paragraph);
    }
    ImpellerParagraphBuilderRelease(pb);
    ImpellerPaintRelease(textPaint);
    ImpellerParagraphStyleRelease(style);
  }

  // <TextInput>. ENG-01b. Paint the field's text (the live edit buffer if this
  // field is focused, else its controlled value), or the placeholder when the
  // field is empty, plus a caret when focused. Uses the SAME Impeller paragraph
  // path as <Text> so metrics match; a single line, no wrapping constraint.
  if (node.isTextInput && typography_ != nullptr) {
    const bool focused = (tiFocused_ == node.tag);
    const std::string shown = focused ? tiEditValue_ : node.tiValue;
    const bool showPlaceholder = shown.empty() && !node.tiPlaceholder.empty();
    const std::string& drawStr = showPlaceholder ? node.tiPlaceholder : shown;
    // Vertically centre the single line in the field's height.
    const float lineH = node.fontSize * 1.2f;
    const float ty = y + (h - lineH) * 0.5f;
    // A small left inset so the glyphs (and caret) do not sit on the border.
    const float pad = 4.0f;
    float caretX = x + pad;
    if (!drawStr.empty()) {
      ImpellerParagraphStyle style = ImpellerParagraphStyleNew();
      ImpellerParagraphStyleSetFontSize(style, node.fontSize);
      ImpellerPaint tPaint = ImpellerPaintNew();
      const float* col = showPlaceholder ? node.tiPlaceholderColor : node.textColor;
      ImpellerColor tc = impellerColor(col, node.opacity);
      ImpellerPaintSetColor(tPaint, &tc);
      ImpellerParagraphStyleSetForeground(style, tPaint);
      ImpellerParagraphBuilder pb = ImpellerParagraphBuilderNew(typography_);
      ImpellerParagraphBuilderPushStyle(pb, style);
      ImpellerParagraphBuilderAddText(pb, (const uint8_t*)drawStr.c_str(),
                                      drawStr.size());
      ImpellerParagraph paragraph =
          ImpellerParagraphBuilderBuildParagraphNew(pb, w > pad ? w - pad : 1e6f);
      if (paragraph != nullptr) {
        ImpellerPoint at = {x + pad, ty};
        ImpellerDisplayListBuilderDrawParagraph(builder, paragraph, &at);
        // The caret sits after the edit buffer up to the caret index. When the
        // caret is at end (the common case: typing appends), the paragraph's
        // max intrinsic width is the advance to place it at. Placeholder text
        // is not editable, so no caret offset is taken from it.
        if (focused && !showPlaceholder) {
          const std::string upto = tiEditValue_.substr(0, tiCaret_);
          if (!upto.empty()) {
            ImpellerParagraphBuilder cb = ImpellerParagraphBuilderNew(typography_);
            ImpellerParagraphBuilderPushStyle(cb, style);
            ImpellerParagraphBuilderAddText(cb, (const uint8_t*)upto.c_str(),
                                            upto.size());
            ImpellerParagraph cpar =
                ImpellerParagraphBuilderBuildParagraphNew(cb, 1e6f);
            if (cpar != nullptr) {
              caretX = x + pad + ImpellerParagraphGetMaxIntrinsicWidth(cpar);
              ImpellerParagraphRelease(cpar);
            }
            ImpellerParagraphBuilderRelease(cb);
          }
        }
        ImpellerParagraphRelease(paragraph);
      }
      ImpellerParagraphBuilderRelease(pb);
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
    if (focused) {
      const long long msSinceReset =
          std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now() - tiCaretResetAt_)
              .count();
      if (caretVisible(msSinceReset)) {
        ImpellerPaint caretPaint = ImpellerPaintNew();
        ImpellerColor cc = impellerColor(node.textColor, node.opacity);
        ImpellerPaintSetColor(caretPaint, &cc);
        ImpellerRect caretRect = {caretX, ty, 1.0f, lineH};
        ImpellerDisplayListBuilderDrawRect(builder, &caretRect, caretPaint);
        ImpellerPaintRelease(caretPaint);
      }
    }
  }

  ImpellerPaintRelease(paint);

  // Children are positioned relative to this node's frame origin.
  const bool clip = node.overflowHidden;
  if (clip) {
    ImpellerDisplayListBuilderSave(builder);
    ImpellerDisplayListBuilderClipRect(builder, &rect,
                                       kImpellerClipOperationIntersect);
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

  // Native (1x) pixel size of the icon's painted box, and the N x offscreen
  // size. Bounded so a pathological full-screen SVG at N=4 cannot ask for a 16k
  // texture and OOM the GPU; past the bound we fall back to in-place.
  const int nativeW = std::max(1, (int)std::ceil(w));
  const int nativeH = std::max(1, (int)std::ceil(h));
  const int pxW = (int)std::ceil(w * (float)N);
  const int pxH = (int)std::ceil(h * (float)N);
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

  if (rounded && uniformWidth && uniformColor) {
    if (!node.hasBorderColors[0] || node.borderColors[0][3] <= 0.0f) return;
    ImpellerPaint paint = ImpellerPaintNew();
    ImpellerColor c = impellerColor(node.borderColors[0], node.opacity);
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
      ImpellerColor c = impellerColor(node.borderColors[e], node.opacity);
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

  for (auto it = node.children.rbegin(); it != node.children.rend(); ++it) {
    auto child = nodes_.find(*it);
    if (child == nodes_.end()) continue;
    if (auto hit = hitTestNode(child->second, childOriginX, childOriginY, x, y))
      return hit;
  }

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
  // item 5: focusing a field shows the caret immediately, then blinks from
  // here. Without this reset the caret's phase would be whatever the free clock
  // happened to be at, so a field could focus into an off phase and look dead.
  tiCaretResetAt_ = std::chrono::steady_clock::now();
}

void SceneGraph::setTextInputEdit(facebook::react::Tag tag,
                                  const std::string& value, size_t caret) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (tiFocused_ != tag) return;  // ignore edits for a field that lost focus
  tiEditValue_ = value;
  tiCaret_ = caret > value.size() ? value.size() : caret;
  // item 5: EVERY keystroke re-shows the caret. This is the half a free-running
  // `(now/500)%2` blink gets wrong -- typing during an off phase would land the
  // character next to an invisible caret. Resetting the phase here guarantees
  // the caret is on for the first half-period after any edit.
  tiCaretResetAt_ = std::chrono::steady_clock::now();
}

void SceneGraph::clearTextInputFocus() {
  std::lock_guard<std::mutex> lock(mutex_);
  tiFocused_ = 0;
  tiEditValue_.clear();
  tiCaret_ = 0;
}

facebook::react::Tag SceneGraph::focusedTextInput() {
  std::lock_guard<std::mutex> lock(mutex_);
  return tiFocused_;
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
  return r;
}

}  // namespace rni
