#pragma once
// ENG-23: one lineHeight setter shared by MEASURE (ImpellerTextLayoutManager)
// and PAINT (SceneGraph Paragraph). RN's TextAttributes::lineHeight is an
// absolute height in points (NaN = unset); Impeller's paragraph style takes the
// line height as a multiple of the font size. Calling this from one place only
// would size a box for one pitch and draw the lines at another.

#include <cmath>

#include "impeller.h"

namespace rni {

// Returns true when a height multiple was applied.
inline bool ApplyLineHeight(ImpellerParagraphStyle style, float lineHeight,
                            float fontSize) {
  if (!(lineHeight > 0.0f) || !std::isfinite(lineHeight) || !(fontSize > 0.0f)) {
    return false;  // unset (NaN/0): the font's own metrics decide the pitch
  }
  ImpellerParagraphStyleSetHeight(style, lineHeight / fontSize);
  return true;
}

}  // namespace rni
