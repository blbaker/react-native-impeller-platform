#include "scenegraph/SceneGraph.h"

#include <react/renderer/core/ConcreteState.h>
#include <react/renderer/graphics/BackgroundImage.h>
#include <react/renderer/graphics/Color.h>
#include <react/renderer/graphics/LinearGradient.h>
#include <react/renderer/graphics/Transform.h>

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

int SceneGraph::paint(ImpellerDisplayListBuilder builder) {
  std::lock_guard<std::mutex> lock(mutex_);
  // Counts every node actually visited, not the roots and not nodes_.size():
  // a gate needs to tell "walked the tree" from "walked one root that had no
  // reachable children", and those differ by exactly this number.
  painted_ = 0;
  for (auto rootTag : roots_) {
    auto it = nodes_.find(rootTag);
    if (it == nodes_.end()) continue;
    paintNode(builder, it->second, 0, 0);
  }
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
