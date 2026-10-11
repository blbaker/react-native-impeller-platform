#include "BackgroundTiles.h"

#include <algorithm>
#include <cmath>
#include <variant>

namespace rni {

namespace react = facebook::react;

namespace {

constexpr size_t kMaxTiles = 4096;

float AxisSize(const std::variant<std::monostate, react::ValueUnit>& v, float box) {
  const auto* u = std::get_if<react::ValueUnit>(&v);
  return u != nullptr ? std::max(u->resolve(box), 0.0f) : box;
}

// Offset of the tile along one axis. Percentages are of (box - tile), as in CSS.
float AxisOffset(const std::optional<react::ValueUnit>& from0,
                 const std::optional<react::ValueUnit>& from1, float box, float tile) {
  const float room = box - tile;
  if (from0) return from0->resolve(room);
  if (from1) return room - from1->resolve(room);
  return 0.0f;
}

// Tile origins along one axis for a repeat style; `tile` is updated by `round`.
std::vector<float> AxisOrigins(react::BackgroundRepeatStyle style, float box, float& tile,
                               float offset) {
  using S = react::BackgroundRepeatStyle;
  std::vector<float> out;
  if (style == S::NoRepeat) {
    out.push_back(offset);
    return out;
  }
  float step = tile, start = offset;
  if (style == S::Round) {
    tile = box / std::max(1.0f, std::round(box / tile));
    step = tile;
  } else if (style == S::Space) {
    const float n = std::floor(box / tile);
    if (n < 2.0f) {
      out.push_back(offset);
      return out;
    }
    step = tile + (box - n * tile) / (n - 1.0f);
    start = 0.0f;
  }
  start -= std::ceil(start / step) * step;  // first tile at or before 0
  for (float p = start; p < box && out.size() < kMaxTiles; p += step) out.push_back(p);
  return out;
}

}  // namespace

void ResolveTileSize(const react::BackgroundSize* size, float w, float h, float& tw, float& th) {
  tw = w;
  th = h;
  if (size == nullptr) return;
  if (const auto* lp = std::get_if<react::BackgroundSizeLengthPercentage>(size)) {
    tw = AxisSize(lp->x, w);
    th = AxisSize(lp->y, h);
  }
}

BgTiling ComputeTiling(const react::BackgroundSize* size, const react::BackgroundPosition* position,
                       const react::BackgroundRepeat* repeat, float w, float h) {
  BgTiling t;
  ResolveTileSize(size, w, h, t.tw, t.th);
  t.tw = std::max(t.tw, 1.0f);
  t.th = std::max(t.th, 1.0f);
  const react::BackgroundRepeat rep = repeat != nullptr ? *repeat : react::BackgroundRepeat{};
  const react::BackgroundPosition pos = position != nullptr ? *position : react::BackgroundPosition{};
  const float ox = AxisOffset(pos.left, pos.right, w, t.tw);
  const float oy = AxisOffset(pos.top, pos.bottom, h, t.th);
  const auto xs = AxisOrigins(rep.x, w, t.tw, ox);
  const auto ys = AxisOrigins(rep.y, h, t.th, oy);
  for (float y : ys) {
    for (float x : xs) {
      if (t.origins.size() < kMaxTiles) t.origins.push_back({x, y});
    }
  }
  t.single = t.origins.size() == 1 && t.origins[0][0] == 0.0f && t.origins[0][1] == 0.0f &&
             t.tw >= w && t.th >= h;
  return t;
}

}  // namespace rni
