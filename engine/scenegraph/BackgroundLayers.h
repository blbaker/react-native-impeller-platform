#pragma once
// experimental_backgroundImage layers (style-coverage B7-B9, A5): linear and
// radial gradients with CSS stop fix-up and colour hints.
#include <array>
#include <functional>
#include <vector>

#include <react/renderer/graphics/BackgroundImage.h>

#include "BackgroundTiles.h"
#include "impeller.h"

namespace rni {

struct BgLayer {
  bool radial{false};
  float start[2]{0, 0};  // linear: gradient line, node-local
  float end[2]{0, 0};
  float center[2]{0, 0};  // radial: node-local centre and radii
  float rx{0}, ry{0};
  std::vector<float> stops;  // 0..1, ascending
  std::vector<std::array<float, 4>> colors;
  // Geometry above is for ONE tile; the tile is painted at each origin, clipped to the box.
  BgTiling tiling;
  float boxW{0}, boxH{0};
};

// One layer per usable entry of `images`, in the order RN lists them (first
// listed paints on top). Entries with fewer than two colour stops are dropped.
// backgroundSize/Position/Repeat cycle over the layers as in CSS.
std::vector<BgLayer> BuildBackgroundLayers(
    const std::vector<facebook::react::BackgroundImage>& images,
    const std::vector<facebook::react::BackgroundSize>& sizes,
    const std::vector<facebook::react::BackgroundPosition>& positions,
    const std::vector<facebook::react::BackgroundRepeat>& repeats, float w, float h);

// Paints the layers bottom-to-top (last listed first). `fillShape` draws the
// node's box shape with the given paint.
void PaintBackgroundLayers(ImpellerDisplayListBuilder builder, const std::vector<BgLayer>& layers,
                           float x, float y, float opacity,
                           const std::function<void(ImpellerPaint)>& fillShape);

}  // namespace rni
