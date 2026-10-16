#include "host/AnimRowProbe.h"

#include <cstdio>
#include <cstdlib>

namespace rni::animrow {

int Row() {
  static const int row = [] {
    const char* v = std::getenv("RNI_TEST_ANIM_ROW");
    if (v == nullptr || *v == '\0') return -1;
    const int y = std::atoi(v);
    return y >= 0 ? y : -1;
  }();
  return row;
}

namespace {
// FP-40: RNI_TEST_ANIM_PIXEL=x,y adds `anim_px present= r= g= b=` (opacity arms).
bool PixelAt(int* x, int* y) {
  static int px = -1, py = -1;
  static const bool ok = [] {
    const char* v = std::getenv("RNI_TEST_ANIM_PIXEL");
    return v != nullptr && std::sscanf(v, "%d,%d", &px, &py) == 2 && px >= 0 && py >= 0;
  }();
  *x = px;
  *y = py;
  return ok;
}
}  // namespace

void OnPresent(const std::vector<Px>& px, int width, int height, int present,
               uint64_t clock, uint64_t frame) {
  const int y = Row();
  int x0 = -1;
  int x1 = -1;
  if (y >= 0 && y < height && px.size() >= (size_t)width * height) {
    const Px* line = &px[(size_t)y * width];
    for (int x = 0; x < width; ++x) {
      const Px& p = line[x];
      if (p.r > 128 && p.g < 96 && p.b < 96) {
        if (x0 < 0) x0 = x;
        x1 = x;
      }
    }
  }
  std::printf("rn-impeller: anim_row present=%d clock=%llu x0=%d x1=%d frame=%llu\n",
              present, (unsigned long long)clock, x0, x1, (unsigned long long)frame);
  int sx = 0, sy = 0;
  if (PixelAt(&sx, &sy) && sx < width && sy < height &&
      px.size() >= (size_t)width * height) {
    const Px& p = px[(size_t)sy * width + sx];
    std::printf("rn-impeller: anim_px present=%d r=%d g=%d b=%d\n", present,
                p.r, p.g, p.b);
  }
}

}  // namespace rni::animrow
