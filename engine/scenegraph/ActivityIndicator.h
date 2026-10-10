#pragma once
// Style-coverage item A20: the iOS UIActivityIndicatorView look.
#include "impeller.h"

namespace rni {

inline constexpr int kSpinnerSpokes = 12;
inline constexpr int kSpinnerStepMs = 83;  // 12 steps ~ one turn per second

// Spoke index (0..11) that is the bright head `msSinceStart` after mount.
inline int SpinnerStep(long long msSinceStart) {
  if (msSinceStart < 0) msSinceStart = 0;
  return static_cast<int>((msSinceStart / kSpinnerStepMs) % kSpinnerSpokes);
}

// Draws 12 rounded spokes inside the (x, y, w, h) frame, centred and sized to
// the shorter side. The spoke at `step` is opaque and the ones behind it fade.
void PaintActivityIndicator(ImpellerDisplayListBuilder builder, float x, float y, float w,
                            float h, const ImpellerColor& color, int step);

}  // namespace rni
