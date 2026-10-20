// See PresentedCapture.h.
#include "host/PresentedCapture.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <set>
#include <string>
#include <thread>

namespace rni::presentedcapture {
namespace {

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

bool Exists(const std::string& path) {  // fopen: portable to every host OS
  FILE* f = std::fopen(path.c_str(), "rb");
  if (f == nullptr) return false;
  std::fclose(f);
  return true;
}

struct State {
  std::string dir;
  std::mutex mu;
  std::vector<Px> px;
  int width = 0, height = 0, present = 0;
  uint64_t frame = 0;
  int64_t presentedMs = 0;
  std::atomic<bool> running{false};
  std::thread watcher;
  std::set<int> served;
};

State* Get() {
  static State* state = []() -> State* {
    const char* v = std::getenv("RNI_TEST_PRESENTED_CAPTURE");
    if (v == nullptr || *v == '\0') return nullptr;
    auto* s = new State();  // leaked on purpose: the raster thread may outlive main's scope
    s->dir = v;
    return s;
  }();
  return state;
}

void Serve(State* s, int k) {
  std::vector<Px> px;
  int w = 0, h = 0, n = 0;
  uint64_t frame = 0;
  int64_t at = 0;
  {
    std::lock_guard<std::mutex> lock(s->mu);
    px = s->px;
    w = s->width;
    h = s->height;
    n = s->present;
    frame = s->frame;
    at = s->presentedMs;
  }
  const std::string base = s->dir + "/shot-" + std::to_string(k);
  const bool ok = n > 0 && WritePpm(base + ".ppm", px, w, h);
  std::printf("rn-impeller: presented_capture k=%d ok=%d present=%d frame=%llu age_ms=%lld\n", k,
              ok ? 1 : 0, n, (unsigned long long)frame, (long long)(n > 0 ? NowMs() - at : -1));
  std::fflush(stdout);
  if (FILE* f = std::fopen((base + ".done").c_str(), "w")) std::fclose(f);
}

}  // namespace

bool Enabled() { return Get() != nullptr; }

void OnPresent(const std::vector<Px>& px, int width, int height, int present,
               uint64_t frameNumber) {
  State* s = Get();
  if (!s || px.size() < (size_t)width * height) return;
  std::lock_guard<std::mutex> lock(s->mu);
  s->px = px;
  s->width = width;
  s->height = height;
  s->present = present;
  s->frame = frameNumber;
  s->presentedMs = NowMs();
}

void Start() {
  State* s = Get();
  if (!s || s->running.exchange(true)) return;
  std::printf("rn-impeller: presented_capture_armed dir=%s\n", s->dir.c_str());
  std::fflush(stdout);
  s->watcher = std::thread([s]() {
    while (s->running.load()) {
      // Requests are numbered from 1; serve each once, in order.
      for (int k = 1; k <= 64; ++k) {
        if (s->served.count(k)) continue;
        if (!Exists(s->dir + "/req-" + std::to_string(k))) break;
        s->served.insert(k);
        Serve(s, k);
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
  });
}

void Stop() {
  State* s = Get();
  if (!s || !s->running.exchange(false)) return;
  if (s->watcher.joinable()) s->watcher.join();
}

}  // namespace rni::presentedcapture
