#pragma once
// Style-coverage item A21: overlay scroll indicators.
#include "impeller.h"

namespace rni {

struct ScrollIndicatorSpec {
  float x, y, w, h;               // viewport in the paint space
  float contentW, contentH;       // content extent (union of the children)
  float scrollX, scrollY;
  bool showVertical, showHorizontal;
  int style;                      // react::ScrollViewIndicatorStyle: 0 default, 1 black, 2 white
};

// Draws a thin rounded bar on the right edge (vertical) and bottom edge
// (horizontal) for each axis whose content overflows the viewport. Bar length
// is viewport/content of the track, position follows the offset.
void PaintScrollIndicators(ImpellerDisplayListBuilder builder, const ScrollIndicatorSpec& s);

}  // namespace rni
