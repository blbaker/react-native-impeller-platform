// iOS host keyboard support (see SceneGraph.h: textInputKeyboardTraits,
// textInputCaretRect). Own TU so SceneGraph.cpp does not grow.
#include "scenegraph/SceneGraph.h"

#include <algorithm>
#include <cmath>

namespace rni {

bool SceneGraph::textInputKeyboardTraits(facebook::react::Tag tag,
                                         TextInputKeyboardTraits* out) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  if (it == nodes_.end() || !it->second.isTextInput) return false;
  *out = it->second.tiKeyboard;
  return true;
}

bool SceneGraph::textInputCaretRect(facebook::react::Tag tag, size_t byteOffset, float* x,
                                    float* y, float* w, float* h) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = nodes_.find(tag);
  if (it == nodes_.end() || !it->second.isTextInput) return false;
  float ox = 0.0f, oy = 0.0f;
  if (!absoluteOriginLocked(tag, &ox, &oy)) return false;
  const auto& frame = it->second.layoutMetrics.frame;
  // The glyph boundary at or before byteOffset: the x the painted caret uses.
  // No text (or no typography yet): the box's left content edge.
  float cx = ox + it->second.layoutMetrics.contentInsets.left;
  std::vector<size_t> offsets;
  std::vector<float> xs;
  if (glyphBoundariesLocked(tag, &offsets, &xs) && !offsets.empty() &&
      offsets.size() == xs.size()) {
    size_t i = 0;
    while (i + 1 < offsets.size() && offsets[i + 1] <= byteOffset) ++i;
    cx = xs[i];
  }
  *x = cx;
  *y = oy;
  *w = 2.0f;
  *h = std::max(1.0f, (float)frame.size.height);
  return true;
}

}  // namespace rni
