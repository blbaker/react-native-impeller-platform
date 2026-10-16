#include "host/ContextLoss.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>

namespace rni::ctxloss {
namespace {

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

std::vector<int> ParseHook() {
  std::vector<int> out;
  const char* v = std::getenv("RNI_TEST_CONTEXT_LOSS_AT_FRAME");
  if (v == nullptr) return out;
  for (const char* p = v; *p != '\0';) {
    char* end = nullptr;
    const long n = std::strtol(p, &end, 10);
    if (end == p) break;
    if (n > 0) out.push_back((int)n);
    p = (*end == ',') ? end + 1 : end;
  }
  std::sort(out.begin(), out.end());
  return out;
}

const std::vector<int>& HookFrames() {
  static const std::vector<int> frames = ParseHook();
  return frames;
}

const std::string& ProbeDir() {
  static const std::string dir = [] {
    const char* v = std::getenv("RNI_TEST_CONTEXT_LOSS_PROBE");
    return std::string(v ? v : "");
  }();
  return dir;
}

constexpr int kProbeFrames = 3;  // presents captured after each recovery

std::mutex gMu;
std::atomic<bool> gLost{false};
std::atomic<bool> gFull{false};
std::atomic<uint64_t> gDropped{0};
std::function<void()> gWake;  // guarded by gMu
int gLosses = 0, gExtraReports = 0, gRecoveries = 0, gFailedRebuilds = 0;
int64_t gLossUs = 0, gRecoverUs = 0, gMaxRebuildUs = 0;
bool gRefWritten = false;
int gPostPresents = -1;  // presents since the last recovery; -1 = none yet

}  // namespace

bool ForceAtPresent(int n) {
  const auto& f = HookFrames();
  return std::binary_search(f.begin(), f.end(), n);
}

void Report(const char* reason, int present, uint64_t frame) {
  std::function<void()> wake;
  {
    std::lock_guard<std::mutex> lock(gMu);
    if (gLost.load(std::memory_order_acquire)) {
      ++gExtraReports;
      return;
    }
    ++gLosses;
    gLossUs = NowUs();
    gLost.store(true, std::memory_order_release);
    std::printf("rn-impeller: context_loss n=%d reason=%s present=%d frame=%llu t_us=%lld\n",
                gLosses, reason, present, (unsigned long long)frame, (long long)gLossUs);
    std::fflush(stdout);
    wake = gWake;
  }
  if (wake) wake();
}

bool Lost() { return gLost.load(std::memory_order_acquire); }

void NoteDropped() { gDropped.fetch_add(1, std::memory_order_relaxed); }

void SetWake(std::function<void()> fn) {
  std::lock_guard<std::mutex> lock(gMu);
  gWake = std::move(fn);
}

void Recovered(bool ok, int64_t rebuildUs, const char* detail) {
  std::lock_guard<std::mutex> lock(gMu);
  if (!ok) {
    ++gFailedRebuilds;
    std::printf("rn-impeller: context_restore n=%d ok=0 detail=%s\n", gLosses, detail);
    std::fflush(stdout);
    return;
  }
  ++gRecoveries;
  gRecoverUs = NowUs();
  gMaxRebuildUs = std::max(gMaxRebuildUs, rebuildUs);
  gPostPresents = 0;
  gFull.store(true, std::memory_order_release);
  std::printf("rn-impeller: context_restore n=%d ok=1 rebuild_us=%lld since_loss_us=%lld "
              "dropped=%llu detail=%s\n",
              gRecoveries, (long long)rebuildUs, (long long)(gRecoverUs - gLossUs),
              (unsigned long long)gDropped.load(), detail);
  std::fflush(stdout);
  gLost.store(false, std::memory_order_release);
}

bool ConsumeFullRepaint() { return gFull.exchange(false, std::memory_order_acq_rel); }

bool WantsCapture(int n) {
  if (ProbeDir().empty()) return false;
  std::lock_guard<std::mutex> lock(gMu);
  if (!gRefWritten && !HookFrames().empty() && n == HookFrames().front()) return true;
  return gRecoveries > 0 && gPostPresents >= 0 && gPostPresents < kProbeFrames;
}

void OnPresent(const std::vector<Px>& px, int w, int h, int n) {
  std::string path;
  {
    std::lock_guard<std::mutex> lock(gMu);
    if (!gRefWritten && gRecoveries == 0) {
      gRefWritten = true;
      path = ProbeDir() + "/ref.ppm";
    } else {
      path = ProbeDir() + "/loss" + std::to_string(gRecoveries) + "-" +
             std::to_string(gPostPresents + 1) + ".ppm";
    }
  }
  const bool ok = WritePpm(path, px, w, h);
  std::printf("rn-impeller: context_loss_probe present=%d file=%s ok=%d\n", n, path.c_str(),
              ok ? 1 : 0);
  std::fflush(stdout);
}

void NotePresent(int n) {
  std::lock_guard<std::mutex> lock(gMu);
  if (gPostPresents < 0) return;
  ++gPostPresents;
  if (gPostPresents == 1) {
    const int64_t now = NowUs();
    std::printf("rn-impeller: context_restore_present n=%d present=%d since_loss_us=%lld "
                "since_restore_us=%lld\n",
                gRecoveries, n, (long long)(now - gLossUs), (long long)(now - gRecoverUs));
    std::fflush(stdout);
  }
}

void PrintSummary() {
  std::lock_guard<std::mutex> lock(gMu);
  std::printf("rn-impeller: context_loss_summary losses=%d recoveries=%d failed_rebuilds=%d "
              "extra_reports=%d dropped=%llu max_rebuild_us=%lld lost_at_exit=%d\n",
              gLosses, gRecoveries, gFailedRebuilds, gExtraReports,
              (unsigned long long)gDropped.load(), (long long)gMaxRebuildUs, Lost() ? 1 : 0);
  std::fflush(stdout);
}

}  // namespace rni::ctxloss
