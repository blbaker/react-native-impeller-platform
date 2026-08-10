#include "scenegraph/SceneGraph.h"

#include <react/renderer/core/ConcreteState.h>
#include <react/renderer/graphics/Color.h>

#include <algorithm>
#include <cstdio>

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

    // Borders: RN carries the value as a CASCADE (all / horizontal / vertical /
    // per-edge / logical start-end), not a number. Resolving it is mandatory —
    // reading `.all` alone silently paints nothing for `borderLeftWidth` and
    // friends. P2 paints the uniform case, so we resolve and take the left edge.
    const auto bw = props->getBorderWidths().resolve(/*isRTL*/ false, 0.0f);
    node.borderWidth = (float)bw.left;
    // Same cascade rule for the colour.
    const auto bc = props->borderColors.resolve(false, facebook::react::SharedColor());
    if (bc.left) {
      node.hasBorderColor = true;
      colorToFloats(bc.left, node.border);
    } else {
      node.hasBorderColor = false;
    }
    // ValueUnit::resolve takes ONE reference length (percentage radii resolve
    // against the box). Use the node's own width.
    const auto& br = props->borderRadii;
    node.borderRadius =
        br.all.has_value()
            ? br.all.value().resolve((float)view.layoutMetrics.frame.size.width)
            : 0.0f;

    node.overflowHidden = props->getClipsContentToBounds();
  }

  // <Text>: the measured AttributedString rides on ParagraphState, which is
  // exactly what Fabric measured with. Painting from the props instead would
  // let measure and paint disagree.
  if (node.componentName == "Paragraph") {
    node.isParagraph = true;
    node.text.clear();
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

  if (node.hasBackgroundColor && node.bg[3] > 0.0f) {
    ImpellerColor c = impellerColor(node.bg, node.opacity);
    ImpellerPaintSetColor(paint, &c);
    if (node.borderRadius > 0.0f) {
      ImpellerRoundingRadii radii = {};
      // Field order is TL, BL, TR, BR — not clockwise.
      radii.top_left = {node.borderRadius, node.borderRadius};
      radii.bottom_left = {node.borderRadius, node.borderRadius};
      radii.top_right = {node.borderRadius, node.borderRadius};
      radii.bottom_right = {node.borderRadius, node.borderRadius};
      ImpellerDisplayListBuilderDrawRoundedRect(builder, &rect, &radii, paint);
    } else {
      ImpellerDisplayListBuilderDrawRect(builder, &rect, paint);
    }
  }

  if (node.borderWidth > 0.0f && node.hasBorderColor && node.border[3] > 0.0f) {
    ImpellerColor c = impellerColor(node.border, node.opacity);
    ImpellerPaintSetColor(paint, &c);
    ImpellerPaintSetDrawStyle(paint, kImpellerDrawStyleStroke);
    ImpellerPaintSetStrokeWidth(paint, node.borderWidth);
    if (node.borderRadius > 0.0f) {
      ImpellerRoundingRadii radii = {};
      radii.top_left = {node.borderRadius, node.borderRadius};
      radii.bottom_left = {node.borderRadius, node.borderRadius};
      radii.top_right = {node.borderRadius, node.borderRadius};
      radii.bottom_right = {node.borderRadius, node.borderRadius};
      ImpellerDisplayListBuilderDrawRoundedRect(builder, &rect, &radii, paint);
    } else {
      ImpellerDisplayListBuilderDrawRect(builder, &rect, paint);
    }
    ImpellerPaintSetDrawStyle(paint, kImpellerDrawStyleFill);
  }

  if (node.isParagraph && !node.text.empty() && typography_ != nullptr) {
    ImpellerParagraphStyle style = ImpellerParagraphStyleNew();
    ImpellerParagraphStyleSetFontSize(style, node.fontSize);
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
