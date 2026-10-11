#pragma once
// Style-coverage item A3: outlineWidth/Color/Style/Offset.
#include "impeller.h"

namespace rni {

// Paints a ring in the band [offset, offset + width] outside the border box
// (x, y, w, h), following `radii`. style: 0 solid, 1 dotted, 2 dashed
// (react::OutlineStyle). Layout and hit testing are not involved.
void PaintOutline(ImpellerDisplayListBuilder builder, float x, float y, float w, float h,
                  const ImpellerRoundingRadii& radii, float width, float offset,
                  int style, const ImpellerColor& color);

}  // namespace rni
