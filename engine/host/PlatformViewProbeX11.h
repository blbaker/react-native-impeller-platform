// FP-44 test hook RNI_TEST_PLATFORM_VIEW_PROBE (linux X11): per present, what
// the background frame shows where the native view must be (the bounding box
// of the marker colour RNI_TEST_PLATFORM_VIEW_MARKER, default 255,0,255, read
// back from GL before the present) next to where the X server has the native
// view (clip window ∩ content window, read back from the server), and after
// the present the screen pixels at "x,y;x,y" (window pixels) when the value
// lists points. Lines: `pv_probe present= frame= hole=l,t,r,b views=`,
// `pv_view present= tag= native=l,t,r,b mapped= overlay=l,t,r,b`,
// `pv_screen present= px=r,g,b;...`.
#pragma once

#include <cstdint>
#include <vector>

#include "host/Pixel.h"

namespace rni::pvprobe {

struct ViewState {
  int tag;
  unsigned long clip, content, overlay;
  bool overlayMapped;
};

bool Enabled();
// `display` is the embedder's Display*.
void BeforePresent(void* display, unsigned long parent, const std::vector<Px>& gl, int w, int h,
                   int present, uint64_t frame, const std::vector<ViewState>& views);
void AfterPresent(void* display, unsigned long parent, int present);

}  // namespace rni::pvprobe
