// FP-17: see PoisonProbe.h.
#include "host/PoisonProbe.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <mutex>

namespace rni::poisonprobe {
namespace {
std::mutex gMu;
int gPresents = 0, gPoisoned = 0, gMaxPx = 0, gFirst = -1;
}  // namespace

bool Enabled() {
  static const bool on = [] {
    const char* v = std::getenv("RNI_TEST_POISON_PROBE");
    return v != nullptr && v[0] == '1';
  }();
  return on;
}

void OnPresent(const std::vector<Px>& px, int width, int height, int present) {
  if (!Enabled() || px.size() < (size_t)width * height) return;
  int n = 0;
  for (size_t i = 0; i < (size_t)width * height; ++i) {
    const Px& p = px[i];
    if (p.r >= 240 && p.g <= 24 && p.b >= 240) ++n;
  }
  std::lock_guard<std::mutex> lock(gMu);
  ++gPresents;
  if (n > 0) {
    ++gPoisoned;
    gMaxPx = std::max(gMaxPx, n);
    if (gFirst < 0) gFirst = present;
  }
}

void PrintSummary() {
  if (!Enabled()) return;
  std::lock_guard<std::mutex> lock(gMu);
  std::printf("rn-impeller: poison_probe presents=%d poisoned=%d max_px=%d first=%d\n", gPresents,
              gPoisoned, gMaxPx, gFirst);
}

}  // namespace rni::poisonprobe
