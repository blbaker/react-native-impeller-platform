// FP-15: see UniformProbe.h.
#include "host/UniformProbe.h"

#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <set>
#include <string>
#include <utility>

namespace rni::uniformprobe {
namespace {

struct State {
  std::vector<std::pair<int, int>> points;
  std::mutex mu;
  int presents = 0;
  int torn = 0;
  int firstTorn = -1;
  std::set<unsigned> colours;
};

State* Get() {
  static State* state = [] () -> State* {
    const char* v = std::getenv("RNI_TEST_UNIFORM_PROBE");
    if (v == nullptr || *v == '\0') return nullptr;
    auto* s = new State();
    std::string spec(v);
    size_t at = 0;
    while (at < spec.size()) {
      size_t end = spec.find(';', at);
      if (end == std::string::npos) end = spec.size();
      int x = 0, y = 0;
      if (std::sscanf(spec.substr(at, end - at).c_str(), "%d,%d", &x, &y) == 2) {
        s->points.emplace_back(x, y);
      }
      at = end + 1;
    }
    return s;
  }();
  return state;
}

}  // namespace

bool Enabled() { return Get() != nullptr; }

void OnPresent(const std::vector<Px>& px, int width, int height, int present) {
  State* s = Get();
  if (!s || px.size() < (size_t)width * height) return;
  bool torn = false;
  unsigned first = 0;
  bool have = false;
  for (const auto& [x, y] : s->points) {
    if (x < 0 || y < 0 || x >= width || y >= height) continue;
    const Px& p = px[(size_t)y * width + x];
    const unsigned c = ((unsigned)p.r << 16) | ((unsigned)p.g << 8) | p.b;
    if (!have) {
      first = c;
      have = true;
    } else if (c != first) {
      torn = true;
    }
  }
  std::lock_guard<std::mutex> lock(s->mu);
  ++s->presents;
  if (torn) {
    ++s->torn;
    if (s->firstTorn < 0) s->firstTorn = present;
  } else if (have) {
    s->colours.insert(first);
  }
}

void PrintSummary() {
  State* s = Get();
  if (!s) return;
  std::lock_guard<std::mutex> lock(s->mu);
  std::printf("rn-impeller: uniform_probe presents=%d torn=%d distinct=%zu "
              "first_torn=%d points=%zu\n",
              s->presents, s->torn, s->colours.size(), s->firstTorn, s->points.size());
  std::fflush(stdout);
}

}  // namespace rni::uniformprobe
