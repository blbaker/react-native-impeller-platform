#pragma once
// Style-coverage item A1: CSS colour-matrix filter functions as one 4x5 matrix.
#include <react/renderer/graphics/Filter.h>

#include <array>
#include <vector>

#include "impeller.h"

namespace rni {

// Composes brightness, contrast, grayscale, hue-rotate, invert, opacity,
// saturate and sepia, in order, into one row-major 4x5 matrix (R,G,B,A rows;
// columns r,g,b,a,offset with the offset in 0..1). Returns false when the list
// has none of those functions (blur and drop-shadow are not colour matrices).
bool BuildFilterMatrix(const std::vector<facebook::react::FilterFunction>& filters,
                       std::array<float, 20>& out);

// Colour filter for the matrix, or null. The caller releases it.
ImpellerColorFilter MakeMatrixColorFilter(const std::array<float, 20>& m);

}  // namespace rni
