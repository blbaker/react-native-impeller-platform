#pragma once
// SC-17: adjustsFontSizeToFit / minimumFontScale. One search shared by MEASURE
// (ImpellerTextLayoutManager) and PAINT (SceneGraph::buildRunParagraph) so both
// shrink the font by the same factor. `shape(scale)` lays the text out at
// `scale` x its font size with no line clamp and no ellipsis, at the real width,
// and returns {line count, longest line width}.
#include <algorithm>
#include <cmath>
#include <utility>

namespace rni {

template <typename Shape>
float FitFontScale(bool enabled, float minScale, int maxLines, float width, Shape shape) {
  if (!enabled || !(width > 0.0f) || width > 1e5f) return 1.0f;
  const float lo = std::isfinite(minScale) ? std::clamp(minScale, 0.01f, 1.0f) : 0.01f;
  const auto fits = [&](float s) {
    const std::pair<int, float> r = shape(s);
    return (maxLines <= 0 || r.first <= maxLines) && r.second <= width + 0.5f;
  };
  if (fits(1.0f)) return 1.0f;
  if (!fits(lo)) return lo;
  float good = lo, bad = 1.0f;
  for (int i = 0; i < 12; ++i) {
    const float mid = 0.5f * (good + bad);
    (fits(mid) ? good : bad) = mid;
  }
  return good;
}

}  // namespace rni
