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

void OnPresent(const std::vector<Px>& px, int width, int height, int present,
               uint64_t clock) {
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
  std::printf("rn-impeller: anim_row present=%d clock=%llu x0=%d x1=%d\n",
              present, (unsigned long long)clock, x0, x1);
}

}  // namespace rni::animrow
