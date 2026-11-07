// Touch drag-to-scroll: which ScrollView a drag moves. See fabric/TouchScroll.h.
#include "scenegraph/SceneGraph.h"

#include <algorithm>

namespace rni {

namespace {

using Nodes = std::unordered_map<facebook::react::Tag, SceneNode>;

// Offset and extent of one ScrollView: the union of its children's frames,
// the same content rule scrollBy and scrollTo use.
SceneGraph::ScrollResult StateOf(const Nodes& nodes, facebook::react::Tag tag,
                                 const SceneNode& sv) {
  SceneGraph::ScrollResult r{};
  for (auto childTag : sv.children) {
    auto child = nodes.find(childTag);
    if (child == nodes.end()) continue;
    const auto& cf = child->second.layoutMetrics.frame;
    r.contentWidth = std::max(r.contentWidth, (float)(cf.origin.x + cf.size.width));
    r.contentHeight = std::max(r.contentHeight, (float)(cf.origin.y + cf.size.height));
  }
  r.tag = tag;
  r.offsetX = sv.scrollX;
  r.offsetY = sv.scrollY;
  r.containerWidth = (float)sv.layoutMetrics.frame.size.width;
  r.containerHeight = (float)sv.layoutMetrics.frame.size.height;
  return r;
}

}  // namespace

// Same nearest-ancestor-on-the-axis walk scrollBy does for the wheel (ENG-02c:
// the axis picks the view), with two touch rules on top: a ScrollView with
// scrollEnabled={false} lets the drag through to the one above it, as on
// Android, and nothing is returned when no ancestor overflows on the axis, so
// JS keeps a drag nothing can scroll (a slider, a PanResponder).
SceneGraph::TouchScrollTarget SceneGraph::touchScrollTargetAt(float x, float y,
                                                              bool horizontal) {
  TouchScrollTarget t{};
  std::lock_guard<std::mutex> lock(mutex_);
  facebook::react::Tag cur = hitTestLocked(x, y);
  int guard = 0;  // a parent-chain cycle must not hang the event thread
  while (cur != 0 && guard++ < 256) {
    auto it = nodes_.find(cur);
    if (it == nodes_.end()) return t;
    const SceneNode& node = it->second;
    if (node.isScrollView && node.scrollEnabled) {
      const ScrollResult s = StateOf(nodes_, cur, node);
      const float overflow = horizontal ? s.contentWidth - s.containerWidth
                                        : s.contentHeight - s.containerHeight;
      if (overflow > 0.0f) {
        t.state = s;
        t.paging = node.pagingEnabled;
        t.decelerationRate = node.decelerationRate;
        return t;
      }
    }
    cur = node.parent;
  }
  return t;
}

SceneGraph::ScrollResult SceneGraph::scrollStateOf(facebook::react::Tag tag) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  if (it == nodes_.end() || !it->second.isScrollView) return ScrollResult{};
  return StateOf(nodes_, tag, it->second);
}

bool SceneGraph::hitIsInside(facebook::react::Tag tag, float x, float y) {
  std::lock_guard<std::mutex> lock(mutex_);
  facebook::react::Tag cur = hitTestLocked(x, y);
  int guard = 0;
  while (cur != 0 && guard++ < 256) {
    if (cur == tag) return true;
    auto it = nodes_.find(cur);
    if (it == nodes_.end()) return false;
    cur = it->second.parent;
  }
  return false;
}

}  // namespace rni
