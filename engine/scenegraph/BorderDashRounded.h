#pragma once
// Style-coverage item B5: dashed / dotted borders on a rounded box, or with a
// different colour per side. See BorderDash.h for the square, one-colour case.
#include "impeller.h"

namespace rni {

// style: react::BorderStyle (1 dotted, 2 dashed). colors/visible are indexed top,
// right, bottom, left; the width must be uniform. Dashes follow the rounded
// centre line clockwise from the end of the top-left corner, with a continuous
// phase around the corners. Returns false when it painted nothing.
bool PaintDashedRoundedBorder(ImpellerDisplayListBuilder builder, int style, float x,
                              float y, float w, float h, float width,
                              const ImpellerColor colors[4], const bool visible[4],
                              const ImpellerRoundingRadii& radii);

}  // namespace rni
