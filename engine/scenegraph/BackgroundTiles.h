#pragma once
// experimental_backgroundSize / Position / Repeat (style-coverage A6): where a
// gradient layer's tiles sit inside the padding box.
#include <array>
#include <vector>

#include <react/renderer/graphics/BackgroundPosition.h>
#include <react/renderer/graphics/BackgroundRepeat.h>
#include <react/renderer/graphics/BackgroundSize.h>

namespace rni {

struct BgTiling {
  float tw{0}, th{0};                    // tile size
  std::vector<std::array<float, 2>> origins;  // tile top-left, node-local
  bool single{true};                     // one tile covering the whole box
};

// `size`, `position` and `repeat` may be null (the CSS defaults: auto size,
// 0 0, repeat). Gradients have no intrinsic size, so auto, cover and contain
// all resolve to the box size.
BgTiling ComputeTiling(const facebook::react::BackgroundSize* size,
                       const facebook::react::BackgroundPosition* position,
                       const facebook::react::BackgroundRepeat* repeat, float w, float h);

// Just the tile size, so the gradient geometry can be built for one tile.
void ResolveTileSize(const facebook::react::BackgroundSize* size, float w, float h,
                     float& tw, float& th);

}  // namespace rni
