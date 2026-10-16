#pragma once

// FP-34: the pipeline pre-warm tour. One display list that draws, at the origin of a 1x1 target,
// every blend mode, clip shape, save-layer, blur, gradient type and text style class the painter
// can emit, so the shader programs and glyph atlas exist before frame 1.
// Model: impeller/entity/contents/content_context.cc (the constructor's CreateDefault prewarm).

#include "impeller.h"

namespace rni {

// What the tour drew, per class (printed in the prewarm line and asserted by the gate).
struct PrewarmCounts {
  int blendModes{0};   // paint blend modes, directly and as a save-layer composite
  int clips{0};        // rect, rounded rect, oval, path (convex and concave), difference
  int layers{0};       // save-layers: plain, opacity, color matrix, tint
  int blurs{0};        // blur image filters, backdrop blur, mask blurs
  int gradients{0};    // linear, radial, conical, sweep, image shader
  int textStyles{0};   // paragraph style classes
  int textures{0};     // texture draws
  int draws{0};        // total draw calls
};

// Raster side (a GL context current). A 1x1 texture the tour samples; the caller releases it.
ImpellerTexture MakePrewarmTexture(ImpellerContext context);

// Main thread (the typography context is single-threaded). `texture` is a 1x1 texture made on the
// raster side, or null to skip the texture draws. Null when the builder fails.
ImpellerDisplayList BuildPrewarmTour(ImpellerTypographyContext typography, ImpellerTexture texture,
                                     PrewarmCounts* counts);

}  // namespace rni
