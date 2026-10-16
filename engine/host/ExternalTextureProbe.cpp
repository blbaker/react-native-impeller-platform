// FP-42: see ExternalTextureProbe.h.
#include "host/ExternalTextureProbe.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <utility>

namespace rni::exttexprobe {

namespace {

const std::vector<std::pair<int, int>>& Points() {
  static const std::vector<std::pair<int, int>> pts = [] {
    std::vector<std::pair<int, int>> out;
    const char* v = std::getenv("RNI_TEST_EXT_TEXTURE_PROBE");
    if (v == nullptr) return out;
    int x = 0, y = 0, n = 0;
    while (std::sscanf(v, "%d,%d%n", &x, &y, &n) == 2) {
      out.emplace_back(x, y);
      v += n;
      if (*v != ';') break;
      ++v;
    }
    return out;
  }();
  return pts;
}

std::atomic<int> gPresents{0};

}  // namespace

bool Enabled() { return !Points().empty(); }

void OnPresent(const std::vector<Px>& px, int width, int height, int present, uint64_t frame,
               const std::string& drawn) {
  std::string vals;
  for (const auto& [x, y] : Points()) {
    char buf[32];
    if (x < 0 || y < 0 || x >= width || y >= height || px.size() < (size_t)width * height) {
      std::snprintf(buf, sizeof buf, "%s-1,-1,-1", vals.empty() ? "" : ";");
    } else {
      const Px& p = px[(size_t)y * width + x];
      std::snprintf(buf, sizeof buf, "%s%d,%d,%d", vals.empty() ? "" : ";", p.r, p.g, p.b);
    }
    vals += buf;
  }
  const long long t = std::chrono::duration_cast<std::chrono::microseconds>(
                          std::chrono::steady_clock::now().time_since_epoch())
                          .count();
  std::printf("rn-impeller: ext_probe present=%d frame=%llu t_us=%lld drawn=%s px=%s\n", present,
              (unsigned long long)frame, t, drawn.empty() ? "-" : drawn.c_str(), vals.c_str());
  std::fflush(stdout);
  gPresents.fetch_add(1, std::memory_order_relaxed);
}

void PrintSummary() {
  if (!Enabled()) return;
  std::printf("rn-impeller: ext_probe_summary presents=%d\n", gPresents.load());
  std::fflush(stdout);
}

}  // namespace rni::exttexprobe
