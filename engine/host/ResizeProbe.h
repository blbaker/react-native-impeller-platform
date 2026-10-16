// FP-30 test hooks for tools/ci-resize-geometry.sh.
//
// RNI_TEST_RESIZE_PROBE=1: every windowed present is read back (raster thread)
// and the reference square (pure red, the fixtures/fp30-resize-geometry square)
// is measured. Its aspect is judged AS DISPLAYED: a compositor stretches a
// frame of w x h onto a window of W x H (CAMetalLayer contentsGravity resize,
// DXGI_SCALING_STRETCH), so the square shows as (bw*W/w) x (bh*H/h).
//   resize_probe present= frame=WxH window=WxH square=x,y,WxH aspect_err=
// Capture(): main, at the moment a resize hands control back to the OS (what
// it composites is the last presented frame):
//   resize_capture n= window=WxH frame=WxH aspect_err= present=
//
// --resize-sequence "F:WxH,F:WxH,...": glfwSetWindowSize(W, H) points after
// loop frame F (several --resize-after-frames in one run).
#pragma once

#include <string>
#include <vector>

#include "host/Pixel.h"

namespace rni {
namespace resizeprobe {

bool Enabled();
// Raster thread, before the present. window = the size the frame must match.
void OnPresent(const std::vector<Px>& px, int w, int h, int present, int windowW,
               int windowH);
// Main.
void Capture(int resizeN, int windowW, int windowH);

struct SizeStep {
  int frame = 0, w = 0, h = 0;
};
// False (and *error) on a malformed spec.
bool ParseSequence(const std::string& spec, std::vector<SizeStep>* out, std::string* error);

}  // namespace resizeprobe
}  // namespace rni
