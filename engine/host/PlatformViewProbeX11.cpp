// FP-44 test hook (see PlatformViewProbeX11.h).
#include "host/PlatformViewProbeX11.h"

#if defined(__linux__) && !defined(__ANDROID__) && RNI_WITH_WINDOW
#include <X11/Xlib.h>
#include <X11/Xutil.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <utility>

namespace rni::pvprobe {
namespace {

struct Rect {
  int l = 0, t = 0, r = 0, b = 0;
  bool Empty() const { return r <= l || b <= t; }
};

std::string Str(const Rect& r) {
  if (r.Empty()) return "-";
  return std::to_string(r.l) + "," + std::to_string(r.t) + "," + std::to_string(r.r) + "," +
         std::to_string(r.b);
}

// The window's rect in `parent` pixels; empty when it is not viewable.
Rect InParent(Display* d, Window parent, Window w, bool* mapped) {
  XWindowAttributes a{};
  if (w == 0 || !XGetWindowAttributes(d, w, &a)) return {};
  if (mapped) *mapped = a.map_state == IsViewable;
  int x = 0, y = 0;
  Window child = 0;
  if (!XTranslateCoordinates(d, w, parent, 0, 0, &x, &y, &child)) return {};
  return Rect{x, y, x + a.width, y + a.height};
}

std::vector<std::pair<int, int>> Points() {
  std::vector<std::pair<int, int>> out;
  const char* e = std::getenv("RNI_TEST_PLATFORM_VIEW_PROBE");
  if (e == nullptr) return out;
  std::string s = e;
  size_t i = 0;
  while (i < s.size()) {
    size_t j = s.find(';', i);
    if (j == std::string::npos) j = s.size();
    int x = 0, y = 0;
    if (std::sscanf(s.substr(i, j - i).c_str(), "%d,%d", &x, &y) == 2) out.push_back({x, y});
    i = j + 1;
  }
  return out;
}

int Channel(unsigned long px, unsigned long mask) {
  if (mask == 0) return 0;
  const int shift = __builtin_ctzl(mask);
  const unsigned long max = mask >> shift;
  return (int)(((px & mask) >> shift) * 255 / max);
}

}  // namespace

bool Enabled() {
  static const bool on = std::getenv("RNI_TEST_PLATFORM_VIEW_PROBE") != nullptr;
  return on;
}

void BeforePresent(void* display, unsigned long parent, const std::vector<Px>& gl, int w, int h,
                   int present, uint64_t frame, const std::vector<ViewState>& views) {
  int mr = 255, mg = 0, mb = 255;
  if (const char* m = std::getenv("RNI_TEST_PLATFORM_VIEW_MARKER")) {
    std::sscanf(m, "%d,%d,%d", &mr, &mg, &mb);
  }
  Rect hole{1 << 30, 1 << 30, -1, -1};
  if ((int)gl.size() == w * h) {
    for (int y = 0; y < h; ++y) {
      for (int x = 0; x < w; ++x) {
        const Px& p = gl[(size_t)y * w + x];
        if (std::abs(p.r - mr) > 8 || std::abs(p.g - mg) > 8 || std::abs(p.b - mb) > 8) continue;
        hole.l = std::min(hole.l, x);
        hole.t = std::min(hole.t, y);
        hole.r = std::max(hole.r, x + 1);
        hole.b = std::max(hole.b, y + 1);
      }
    }
  }
  std::printf("rn-impeller: pv_probe present=%d frame=%llu hole=%s views=%zu\n", present,
              (unsigned long long)frame, Str(hole).c_str(), views.size());
  auto* d = (Display*)display;
  for (const auto& v : views) {
    bool clipMapped = false, contentMapped = false, ovMapped = false;
    const Rect c = InParent(d, parent, v.clip, &clipMapped);
    const Rect k = InParent(d, parent, v.content, &contentMapped);
    Rect native{std::max(c.l, k.l), std::max(c.t, k.t), std::min(c.r, k.r), std::min(c.b, k.b)};
    if (!clipMapped || !contentMapped) native = Rect{};
    const Rect o = v.overlayMapped ? InParent(d, parent, v.overlay, &ovMapped) : Rect{};
    std::printf("rn-impeller: pv_view present=%d tag=%d native=%s mapped=%d overlay=%s\n",
                present, v.tag, Str(native).c_str(), (clipMapped && contentMapped) ? 1 : 0,
                Str(ovMapped ? o : Rect{}).c_str());
  }
  std::fflush(stdout);
}

void AfterPresent(void* display, unsigned long parent, int present) {
  static const std::vector<std::pair<int, int>> points = Points();
  if (points.empty()) return;
  auto* d = (Display*)display;
  XWindowAttributes a{};
  if (!XGetWindowAttributes(d, parent, &a)) return;
  std::string out;
  for (const auto& [x, y] : points) {
    XImage* img = XGetImage(d, parent, x, y, 1, 1, AllPlanes, ZPixmap);
    if (!out.empty()) out += ";";
    if (img == nullptr) {
      out += "-";
      continue;
    }
    const unsigned long px = XGetPixel(img, 0, 0);
    out += std::to_string(Channel(px, a.visual->red_mask)) + "," +
           std::to_string(Channel(px, a.visual->green_mask)) + "," +
           std::to_string(Channel(px, a.visual->blue_mask));
    XDestroyImage(img);
  }
  std::printf("rn-impeller: pv_screen present=%d px=%s\n", present, out.c_str());
  std::fflush(stdout);
}

}  // namespace rni::pvprobe

#else

namespace rni::pvprobe {
bool Enabled() { return false; }
void BeforePresent(void*, unsigned long, const std::vector<Px>&, int, int, int, uint64_t,
                   const std::vector<ViewState>&) {}
void AfterPresent(void*, unsigned long, int) {}
}  // namespace rni::pvprobe

#endif
