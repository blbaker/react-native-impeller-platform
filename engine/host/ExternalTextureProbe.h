// FP-42 test hook: RNI_TEST_EXT_TEXTURE_PROBE="x,y;x,y;..." (framebuffer px)
// reads every windowed present back on the raster thread before the present and
// prints, per present:
//   ext_probe present= frame= t_us= drawn=<id:seq:marks,...> px=r,g,b;r,g,b;...
// drawn = what RECORD put in this frame (seq 0: registered, nothing drawn;
// marks: MarkFrameAvailable calls the registry had seen when it resolved).
// Exit: `ext_probe_summary presents=`. Unset: nothing is read back.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "host/Pixel.h"

namespace rni::exttexprobe {

bool Enabled();
void OnPresent(const std::vector<Px>& px, int width, int height, int present, uint64_t frame,
               const std::string& drawn);
void PrintSummary();  // no-op when disabled

}  // namespace rni::exttexprobe
