#pragma once
// Style-coverage items A1 (blur, drop-shadow) and B11 (iOS shadow cast by content).
//
// A content shadow is the subtree painted a second time into a layer that
// keeps only its alpha, tinted to the shadow colour, blurred, and offset. It
// sits under the real paint inside the node's transform/opacity/filter layers.
#include <react/renderer/graphics/Filter.h>

#include <vector>

#include "impeller.h"
#include "scenegraph/Shadows.h"

namespace rni {

// Sum of the blur() sigmas (CSS: blur(r) is a gaussian of standard deviation
// r) and one ShadowSpec per drop-shadow(), sigma = blur length / 2 as for
// boxShadow. Colour defaults to black.
void ParseContentFilters(const std::vector<facebook::react::FilterFunction>& filters,
                         float& blurSigma, std::vector<ShadowSpec>& dropShadows);

// Gaussian blur image filter (decal edges), or null for sigma <= 0. The caller releases it.
ImpellerImageFilter MakeBlurImageFilter(float sigma);

// Opens the shadow layer: save, translate by the offset, save-layer whose
// paint replaces colour with the shadow colour (alpha kept) and blurs.
// Paint the subtree, then call EndContentShadow.
void BeginContentShadow(ImpellerDisplayListBuilder builder, const ShadowSpec& s);
void EndContentShadow(ImpellerDisplayListBuilder builder);

}  // namespace rni
