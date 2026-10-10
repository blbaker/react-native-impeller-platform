#pragma once
// Style-coverage item A7: borderCurve 'continuous' (the iOS squircle corner).
#include "impeller.h"

namespace rni {

// Rounded rect whose corners use the iOS continuous curve, scaled so each corner
// stays inside its rx x ry box (the same box a circular corner occupies).
// The caller releases the path. Returns nullptr when Impeller gives none.
ImpellerPath MakeContinuousRRectPath(float x, float y, float w, float h,
                                     const ImpellerRoundingRadii& radii);

}  // namespace rni
