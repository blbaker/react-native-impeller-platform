#pragma once
// Style-coverage item B4: a rounded box whose edges differ in width or colour.
#include "impeller.h"

namespace rni {

// widths/colors/visible are indexed top, right, bottom, left. The ring between
// the outer rounded rect and the inner (content) rounded rect is split into four
// mitred wedges, one per edge, each filled in that edge's colour.
void PaintRoundedMixedBorder(ImpellerDisplayListBuilder builder, float x, float y,
                             float w, float h, const float widths[4],
                             const ImpellerColor colors[4], const bool visible[4],
                             const ImpellerRoundingRadii& radii);

}  // namespace rni
