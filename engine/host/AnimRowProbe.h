// FP-10 test hook: one row of the presented frame, read back per present.
//
// RNI_TEST_ANIM_ROW=<y> makes every windowed present print
//   anim_row present=<n> clock=<animation clock frame> x0=<first> x1=<last>
// where x0/x1 are the first and last columns on framebuffer row y whose pixel
// is fixture red (r > 128, g < 96, b < 96), or -1 when the row has none. The
// gate maps x0 back onto the analytic Animated.timing curve, so the lag it
// reports is read from pixels that reached the window, not from a prop value.
// Unset: Enabled() is false and the loop does no readback.
#pragma once

#include "host/Pixel.h"

#include <cstdint>
#include <vector>

namespace rni::animrow {

// Row to sample, or -1 when RNI_TEST_ANIM_ROW is unset or invalid.
int Row();
inline bool Enabled() { return Row() >= 0; }

// px is top-left ordered, width*height. Prints one anim_row line.
void OnPresent(const std::vector<Px>& px, int width, int height, int present,
               uint64_t clock);

}  // namespace rni::animrow
