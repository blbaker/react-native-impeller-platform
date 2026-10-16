// FP-54. Model: flutter/shell/common/shell.cc Shell::OnFrameRasterized.
#include "base/DevToolsFrames.h"

#include <atomic>
#include <memory>
#include <mutex>

namespace rni::devtools {
namespace {

std::atomic<bool> gRecording{false};
std::atomic<uint64_t> gCommits{0};
std::atomic<uint64_t> gEmitted{0};
std::atomic<uint64_t> gSessions{0};
std::mutex gMutex;
std::shared_ptr<const FrameSink> gSink;

}  // namespace

Stats GetStats() {
  return {gCommits.load(), gEmitted.load(), gSessions.load()};
}

Stats StartRecording(FrameSink sink) {
  std::lock_guard<std::mutex> lock(gMutex);
  gSink = std::make_shared<const FrameSink>(std::move(sink));
  gSessions.fetch_add(1);
  gRecording.store(true);
  return GetStats();
}

Stats StopRecording() {
  std::lock_guard<std::mutex> lock(gMutex);
  gRecording.store(false);
  gSink.reset();
  return GetStats();
}

bool Recording() { return gRecording.load(std::memory_order_relaxed); }

void OnFrameCommitted(const FrameRecord& frame) {
  gCommits.fetch_add(1, std::memory_order_relaxed);
  // Flutter: `if (!needs_report_timings_) return;`
  if (!gRecording.load(std::memory_order_relaxed)) return;
  std::shared_ptr<const FrameSink> sink;
  {
    std::lock_guard<std::mutex> lock(gMutex);
    sink = gSink;
  }
  if (!sink) return;
  // Called WITHOUT gMutex: the sink takes HostTarget's tracing mutex, which
  // onTracingStopped holds while it calls StopRecording (lock-order inversion).
  gEmitted.fetch_add(1, std::memory_order_relaxed);
  (*sink)(frame);
}

}  // namespace rni::devtools
