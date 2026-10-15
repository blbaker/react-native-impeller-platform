// FP-15 test hook: torn-frame probe for ci-raster-thread arm B.
//
// RNI_TEST_UNIFORM_PROBE="x,y;x,y;..." (framebuffer pixels) reads every
// windowed present back on the raster thread, before the present, and checks
// that all sample points carry ONE colour. The fixture paints N boxes that
// share one colour per commit, so a present mixing two commits (a torn frame)
// shows up as two colours among the samples. Prints at exit:
//   uniform_probe presents= torn= distinct= first_torn=
// distinct = how many different uniform colours were seen (proves commits
// reached the screen). Unset: Enabled() is false and nothing is read back.
#pragma once

#include "host/Pixel.h"

#include <vector>

namespace rni::uniformprobe {

bool Enabled();
// px is top-left ordered, width*height. Raster thread.
void OnPresent(const std::vector<Px>& px, int width, int height, int present);
void PrintSummary();  // no-op when disabled

}  // namespace rni::uniformprobe
