// See MemTrim.h.
#include "base/MemTrim.h"

#include "base/Trace.h"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <thread>

#if defined(__linux__) && defined(__GLIBC__)
#include <malloc.h>
#define RNI_MEMTRIM_GLIBC 1
#else
#define RNI_MEMTRIM_GLIBC 0
#endif

namespace rni::memtrim {
namespace {

using Clock = std::chrono::steady_clock;

// Why these values (measured on an RK3588 board, 8 GB):
// - arena_max 4: the console grew 40+ arenas (ffmpeg's 9 decode threads, 4 image
//   decoders, mali, raster, js), and each kept its own free memory.
// - mmap threshold 1 MiB: a frame- or bitmap-sized block gets its own mapping
//   and goes back to the kernel on free. Setting it also stops glibc raising it
//   to the largest block freed. The video and web view producers recycle their
//   frame buffers (scenegraph/FrameRecycler.h), so no frame pays for a mapping.
// - trim threshold 4 MiB: an arena gives its top back once 4 MiB is free there.
constexpr int kArenaMax = 4;
constexpr int kMmapThreshold = 1 << 20;
constexpr int kTrimThreshold = 4 << 20;
// A screen change or a player teardown frees in many steps: trim once, after.
constexpr auto kQuiet = std::chrono::milliseconds(1500);

struct State {
  std::mutex mu;
  std::condition_variable cv;
  bool started = false;
  bool pending = false;
  Clock::time_point due;
  std::string why;
  int requests = 0;
  int statsSec = 0;
  Clock::time_point nextStats;
  std::function<std::string()> extra;
  unsigned long long trims = 0;
};

State& S() {
  static State* s = new State();  // leaked: the worker thread may outlive static teardown
  return *s;
}

void ReadRss(long* rss, long* anon) {
  *rss = *anon = -1;
  FILE* f = std::fopen("/proc/self/status", "r");
  if (f == nullptr) return;
  char line[256];
  while (std::fgets(line, sizeof line, f)) {
    if (std::strncmp(line, "VmRSS:", 6) == 0) *rss = std::atol(line + 6);
    if (std::strncmp(line, "RssAnon:", 8) == 0) *anon = std::atol(line + 8);
  }
  std::fclose(f);
}

int CountArenas() {
#if RNI_MEMTRIM_GLIBC
  char* buf = nullptr;
  size_t len = 0;
  FILE* f = open_memstream(&buf, &len);
  if (f == nullptr) return -1;
  malloc_info(0, f);
  std::fclose(f);
  int n = 0;
  for (const char* p = buf; p != nullptr && (p = std::strstr(p, "<heap nr=")) != nullptr; ++p) ++n;
  std::free(buf);
  return n;
#else
  return -1;
#endif
}

void PrintStats(const char* when) {
  long rss = 0, anon = 0;
  ReadRss(&rss, &anon);
  std::function<std::string()> extra;
  unsigned long long trims = 0;
  {
    std::lock_guard<std::mutex> lock(S().mu);
    extra = S().extra;
    trims = S().trims;
  }
  const std::string more = extra ? extra() : std::string();
#if RNI_MEMTRIM_GLIBC
  const struct mallinfo2 mi = mallinfo2();
  std::printf("rn-impeller: mem_stats when=%s rss_kb=%ld anon_kb=%ld malloc_used_kb=%zu malloc_free_kb=%zu "
              "malloc_mmap_kb=%zu arenas=%d trims=%llu %s\n",
              when, rss, anon, mi.uordblks / 1024, mi.fordblks / 1024, mi.hblkhd / 1024, CountArenas(), trims,
              more.c_str());
#else
  std::printf("rn-impeller: mem_stats when=%s rss_kb=%ld anon_kb=%ld trims=%llu %s\n", when, rss, anon, trims,
              more.c_str());
#endif
  std::fflush(stdout);
}

void Trim(const std::string& why, int requests) {
  long rssBefore = 0, anonBefore = 0, rssAfter = 0, anonAfter = 0;
  ReadRss(&rssBefore, &anonBefore);
  const auto t0 = Clock::now();
#if RNI_MEMTRIM_GLIBC
  malloc_trim(0);
#endif
  const double ms = std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
  ReadRss(&rssAfter, &anonAfter);
  bool stats = false;
  {
    std::lock_guard<std::mutex> lock(S().mu);
    ++S().trims;
    stats = S().statsSec > 0;
  }
  std::printf("rn-impeller: mem_trim why=%s requests=%d rss_before_kb=%ld rss_after_kb=%ld freed_kb=%ld ms=%.1f\n",
              why.c_str(), requests, rssBefore, rssAfter, rssBefore - rssAfter, ms);
  std::fflush(stdout);
  if (stats) PrintStats("trim");
}

void Run() {
  // Named here: a new thread inherits its creator's name, and the first Request() often comes
  // from an rni-image-io worker, which made this thread look like a fifth image IO worker.
  rni::trace::SetThreadName("rni-mem-trim");
  State& s = S();
  std::unique_lock<std::mutex> lock(s.mu);
  for (;;) {
    Clock::time_point wake = Clock::time_point::max();
    if (s.pending) wake = s.due;
    if (s.statsSec > 0) wake = std::min(wake, s.nextStats);
    if (wake == Clock::time_point::max()) {
      s.cv.wait(lock);
    } else {
      s.cv.wait_until(lock, wake);
    }
    const auto now = Clock::now();
    if (s.pending && now >= s.due) {
      const std::string why = std::move(s.why);
      const int n = s.requests;
      s.why.clear();
      s.pending = false;
      s.requests = 0;
      lock.unlock();
      Trim(why, n);
      lock.lock();
    }
    if (s.statsSec > 0 && now >= s.nextStats) {
      s.nextStats = now + std::chrono::seconds(s.statsSec);
      lock.unlock();
      PrintStats("tick");
      lock.lock();
    }
  }
}

void EnsureStartedLocked(State& s) {
  if (s.started) return;
  s.started = true;
  std::thread([] { Run(); }).detach();  // never joined: it only touches libc and the leaked State
}

[[maybe_unused]] bool TrimDisabled() {
  static const bool off = [] {
    const char* v = std::getenv("RNI_MEM_TRIM");
    return v != nullptr && std::strcmp(v, "0") == 0;
  }();
  return off;
}

}  // namespace

void Configure() {
#if RNI_MEMTRIM_GLIBC
  const char* policy = std::getenv("RNI_MALLOC_POLICY");
  const char* tunables = std::getenv("GLIBC_TUNABLES");
  const char* chosen = std::getenv("MALLOC_ARENA_MAX")         ? "MALLOC_ARENA_MAX"
                       : std::getenv("MALLOC_MMAP_THRESHOLD_") ? "MALLOC_MMAP_THRESHOLD_"
                       : std::getenv("MALLOC_TRIM_THRESHOLD_") ? "MALLOC_TRIM_THRESHOLD_"
                       : (tunables && std::strstr(tunables, "glibc.malloc.")) ? "GLIBC_TUNABLES"
                                                                               : nullptr;
  if (policy != nullptr && std::strcmp(policy, "off") == 0) {
    std::printf("rn-impeller: malloc_policy=off source=RNI_MALLOC_POLICY\n");
  } else if (chosen != nullptr) {
    std::printf("rn-impeller: malloc_policy=env source=%s\n", chosen);
  } else {
    const bool ok = mallopt(M_ARENA_MAX, kArenaMax) == 1 && mallopt(M_MMAP_THRESHOLD, kMmapThreshold) == 1 &&
                    mallopt(M_TRIM_THRESHOLD, kTrimThreshold) == 1;
    std::printf("rn-impeller: malloc_policy=engine arena_max=%d mmap_threshold=%d trim_threshold=%d ok=%d\n",
                kArenaMax, kMmapThreshold, kTrimThreshold, ok ? 1 : 0);
  }
  std::printf("rn-impeller: mem_trim_enabled=%d\n", TrimDisabled() ? 0 : 1);
  std::fflush(stdout);
#endif
}

void Request(const char* why) {
#if RNI_MEMTRIM_GLIBC
  if (TrimDisabled()) return;
  State& s = S();
  {
    std::lock_guard<std::mutex> lock(s.mu);
    s.pending = true;
    s.due = Clock::now() + kQuiet;
    ++s.requests;
    const std::string w = why ? why : "?";
    if (("," + s.why + ",").find("," + w + ",") == std::string::npos) s.why += (s.why.empty() ? "" : ",") + w;
    EnsureStartedLocked(s);
  }
  s.cv.notify_one();
#else
  (void)why;
#endif
}

void SetStatsExtra(std::function<std::string()> extra) {
  std::lock_guard<std::mutex> lock(S().mu);
  S().extra = std::move(extra);
}

void StartStats() {
  const char* v = std::getenv("RNI_MEM_STATS_SEC");
  const int sec = v ? std::atoi(v) : 0;
  if (sec <= 0) return;
  State& s = S();
  {
    std::lock_guard<std::mutex> lock(s.mu);
    s.statsSec = sec;
    s.nextStats = Clock::now();
    EnsureStartedLocked(s);
  }
  s.cv.notify_one();
}

}  // namespace rni::memtrim
