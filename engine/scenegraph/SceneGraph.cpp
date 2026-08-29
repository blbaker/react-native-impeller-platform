#include "scenegraph/SceneGraph.h"

#include <react/renderer/core/ConcreteState.h>
#include <react/renderer/graphics/BackgroundImage.h>
#include <react/renderer/graphics/Color.h>
#include <react/renderer/graphics/LinearGradient.h>
#include <react/renderer/graphics/Transform.h>

#if RNI_WITH_RNSVG
#include <react/renderer/components/rnsvg/Props.h>
#include "svg/SvgPath.h"
#endif

#include <algorithm>
#include <cmath>
#include <cstdio>
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
template <typename P>
void readSvgPaintProps(SceneNode& node, const P* pp) {
  node.svgHasFill = svgFillFromDynamic(pp->fill, node.svgFillColor);
  node.svgFillOpacity = (float)pp->fillOpacity;
  // fillRule: 0 = evenodd, 1 = nonzero.
  node.svgFillEvenOdd = (pp->fillRule == 0);

  node.svgHasStroke = svgFillFromDynamic(pp->stroke, node.svgStrokeColor);
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

void SceneGraph::updateFromShadowView(SceneNode& node,
                                      const react::ShadowView& view) {
  node.tag = view.tag;
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
    if (const auto* pp =
            dynamic_cast<const react::ParagraphProps*>(view.props.get())) {
      node.maxLines = pp->paragraphAttributes.maximumNumberOfLines;
    }
    if (view.state) {
      // The state type is ParagraphShadowNode::ConcreteStateData's holder;
      // spelling it via the shadow node avoids guessing the template args.
      const auto& stateData =
          static_cast<const facebook::react::ConcreteState<
              facebook::react::ParagraphState>&>(*view.state)
              .getData();
      for (const auto& fragment : stateData.attributedString.getFragments()) {
        node.text += fragment.string;
        if (fragment.textAttributes.fontSize > 0) {
          node.fontSize = (float)fragment.textAttributes.fontSize;
        }
        if (fragment.textAttributes.foregroundColor) {
          colorToFloats(fragment.textAttributes.foregroundColor, node.textColor);
        }
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

void SceneGraph::paintNode(ImpellerDisplayListBuilder builder,
                           const SceneNode& node, float originX,
                           float originY) {
  const auto& frame = node.layoutMetrics.frame;
  const float x = originX + (float)frame.origin.x;
  const float y = originY + (float)frame.origin.y;
  const float w = (float)frame.size.width;
  const float h = (float)frame.size.height;

  ++painted_;
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
  if (node.isSvgPath && (node.svgHasFill || node.svgHasStroke) &&
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

  ImpellerPaintRelease(paint);

  // Children are positioned relative to this node's frame origin.
  const bool clip = node.overflowHidden;
  if (clip) {
    ImpellerDisplayListBuilderSave(builder);
    ImpellerDisplayListBuilderClipRect(builder, &rect,
                                       kImpellerClipOperationIntersect);
  }
  for (auto childTag : node.children) {
    auto it = nodes_.find(childTag);
    if (it != nodes_.end()) {
      paintNode(builder, it->second, x, y);
    }
  }
  if (clip) {
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

int SceneGraph::paint(ImpellerDisplayListBuilder builder,
                      float pointScaleFactor) {
  std::lock_guard<std::mutex> lock(mutex_);
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

}  // namespace rni
