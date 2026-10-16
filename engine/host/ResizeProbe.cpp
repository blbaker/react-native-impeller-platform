// FP-30: see ResizeProbe.h.
#include "host/ResizeProbe.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>

namespace rni {
namespace resizeprobe {
namespace {

std::mutex gMu;
int gFrameW = 0, gFrameH = 0, gPresent = 0, gBw = 0, gBh = 0;

// Aspect of a bw x bh square in a w x h frame shown on a W x H window.
double AspectErr(int bw, int bh, int w, int h, int windowW, int windowH) {
  if (bw <= 0 || bh <= 0 || w <= 0 || h <= 0 || windowW <= 0 || windowH <= 0) return 1.0;
  const double dispW = (double)bw * windowW / w;
  const double dispH = (double)bh * windowH / h;
  return std::fabs(dispW / dispH - 1.0);
}

bool IsRed(const Px& p) { return p.r >= 200 && p.g <= 60 && p.b <= 60; }

}  // namespace

bool Enabled() {
  static const bool on = [] {
    const char* v = std::getenv("RNI_TEST_RESIZE_PROBE");
    return v && std::strcmp(v, "1") == 0;
  }();
  return on;
}

void OnPresent(const std::vector<Px>& px, int w, int h, int present, int windowW,
               int windowH) {
  if ((int)px.size() < w * h || w <= 0 || h <= 0) return;
  int x0 = w, y0 = h, x1 = -1, y1 = -1;
  for (int y = 0; y < h; ++y) {
    const Px* row = &px[(size_t)y * w];
    for (int x = 0; x < w; ++x) {
      if (!IsRed(row[x])) continue;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  const int bw = x1 >= x0 ? x1 - x0 + 1 : 0;
  const int bh = y1 >= y0 ? y1 - y0 + 1 : 0;
  const double err = AspectErr(bw, bh, w, h, windowW, windowH);  // no square = 1.0
  {
    std::lock_guard<std::mutex> lock(gMu);
    gFrameW = w;
    gFrameH = h;
    gPresent = present;
    gBw = bw;
    gBh = bh;
  }
  std::printf("rn-impeller: resize_probe present=%d frame=%dx%d window=%dx%d square=%d,%d,%dx%d "
              "aspect_err=%.4f\n",
              present, w, h, windowW, windowH, x0, y0, bw, bh, err);
  std::fflush(stdout);
}

void Capture(int resizeN, int windowW, int windowH) {
  int fw, fh, present, bw, bh;
  {
    std::lock_guard<std::mutex> lock(gMu);
    fw = gFrameW;
    fh = gFrameH;
    present = gPresent;
    bw = gBw;
    bh = gBh;
  }
  // The last presented frame, shown on the window as it is now.
  const double err = AspectErr(bw, bh, fw, fh, windowW, windowH);
  std::printf("rn-impeller: resize_capture n=%d window=%dx%d frame=%dx%d aspect_err=%.4f "
              "present=%d\n",
              resizeN, windowW, windowH, fw, fh, err, present);
  std::fflush(stdout);
}

bool ParseSequence(const std::string& spec, std::vector<SizeStep>* out, std::string* error) {
  out->clear();
  size_t pos = 0;
  while (pos < spec.size()) {
    size_t end = spec.find(',', pos);
    if (end == std::string::npos) end = spec.size();
    const std::string item = spec.substr(pos, end - pos);
    SizeStep s;
    if (std::sscanf(item.c_str(), "%d:%dx%d", &s.frame, &s.w, &s.h) != 3 || s.frame <= 0 ||
        s.w <= 0 || s.h <= 0) {
      *error = "--resize-sequence wants F:WxH[,F:WxH...] with all > 0 (got " + item + ")";
      return false;
    }
    out->push_back(s);
    pos = end + 1;
  }
  if (out->empty()) *error = "--resize-sequence is empty";
  return !out->empty();
}

}  // namespace resizeprobe
}  // namespace rni
