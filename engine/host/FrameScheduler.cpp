// FP-11: see FrameScheduler.h. Model: flutter/shell/common/animator.cc and
// shell/common/vsync_waiter_fallback.cc.
#include "host/FrameScheduler.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>

#include "base/Trace.h"

namespace rni {
namespace {

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// vsync_waiter_fallback.cc SnapToNextTick: the first tick at or after `value`
// on the grid phase + k * interval.
int64_t SnapToNextTick(int64_t value, int64_t phase, int64_t interval) {
  int64_t offset = (phase - value) % interval;
  if (offset != 0) offset += interval;
  return value + offset % interval;
}

}  // namespace

FrameScheduler::FrameScheduler(Options options, WaitFn wait, WakeFn wake,
                               SwapIntervalFn swapInterval)
    : options_(options),
      wait_(std::move(wait)),
      wake_(std::move(wake)),
      swapInterval_(std::move(swapInterval)),
      source_(options.source),
      period_(1.0 / (options.hz > 0.0 ? options.hz : 60.0)),
      phaseUs_(NowUs()) {
  // kAuto probes with swap interval 1: a platform that honours it blocks in
  // the swap and keeps that source; one that does not gets the software clock.
  const int interval = source_ == Source::kFree || source_ == Source::kSoftware ? 0 : 1;
  if (swapInterval_ && source_ != Source::kPlatform) swapInterval_(interval);
  std::printf("rn-impeller: vsync requested=%s swap_interval=%d period_us=%lld\n",
              SourceName(source_), interval, (long long)(period_ * 1e6));
  std::fflush(stdout);
}

bool FrameScheduler::ParseSource(const char* text, Source* out) {
  if (!std::strcmp(text, "auto")) *out = Source::kAuto;
  else if (!std::strcmp(text, "swap")) *out = Source::kSwapInterval;
  else if (!std::strcmp(text, "software")) *out = Source::kSoftware;
  else if (!std::strcmp(text, "off")) *out = Source::kFree;
  else if (!std::strcmp(text, "platform")) *out = Source::kPlatform;
  else return false;
  return true;
}

const char* FrameScheduler::SourceName(Source s) {
  switch (s) {
    case Source::kAuto: return "auto";
    case Source::kSwapInterval: return "swap";
    case Source::kSoftware: return "software";
    case Source::kFree: return "off";
    case Source::kPlatform: return "platform";
  }
  return "?";
}

void FrameScheduler::RequestFrame(const char* reason) {
  requests_.fetch_add(1, std::memory_order_relaxed);
  int expected = 0;
  if (!pending_.compare_exchange_strong(expected, 1, std::memory_order_acq_rel)) {
    coalesced_.fetch_add(1, std::memory_order_relaxed);  // one outstanding request
    return;
  }
  if (options_.log) {
    std::printf("rn-impeller: vsync_request reason=%s t_us=%lld\n", reason,
                (long long)NowUs());
    std::fflush(stdout);
  }
  if (wake_) wake_();
}

bool FrameScheduler::FramePending() const {
  return pending_.load(std::memory_order_acquire) > 0;
}

void FrameScheduler::AwaitVsync() {
  // VsyncWaiter fires every callback registered for one interval together, so
  // frames still owed to the last tick run without waiting for another one.
  if (burst_ > 0) {
    --burst_;
    maxFramesPerTick_ = std::max(maxFramesPerTick_, ++framesThisTick_);
    return;
  }
  if (source_ == Source::kSoftware) {
    TRACE_EVENT0("frame", "AwaitVsync");
    const int64_t interval = (int64_t)(period_ * 1e6);
    const int64_t target = SnapToNextTick(NowUs(), phaseUs_, interval);
    for (;;) {
      const int64_t rem = target - NowUs();
      if (rem <= 0) break;
      // Park in the event wait (input still dispatches) until ~1.5 ms before
      // the tick, then sleep the rest: the event wait has ms granularity.
      if (rem > 2000 && wait_) wait_((double)(rem - 1500) / 1e6);
      else std::this_thread::sleep_for(std::chrono::microseconds(rem));
    }
  }
  ++ticks_;
  tickUs_ = NowUs();
  framesThisTick_ = 1;
  maxFramesPerTick_ = std::max(maxFramesPerTick_, 1);
  burst_ = std::max(0, pending_.load(std::memory_order_acquire) - 1);
}

uint64_t FrameScheduler::BeginFrame() {
  if (pending_.load(std::memory_order_acquire) > 0) {
    pending_.fetch_sub(1, std::memory_order_acq_rel);
  }
  return ++frames_;
}

void FrameScheduler::WillPresent() { presentStartUs_ = NowUs(); }

void FrameScheduler::DidPresent(int presentNumber) {
  const int64_t now = NowUs();
  const int64_t swapUs = now - presentStartUs_;
  if (options_.log) {
    std::printf("rn-impeller: vsync_present n=%d t_us=%lld swap_us=%lld "
                "interval_us=%lld since_vsync_us=%lld source=%s\n",
                presentNumber, (long long)now, (long long)swapUs,
                (long long)(lastPresentUs_ ? now - lastPresentUs_ : 0),
                (long long)(now - tickUs_), SourceName(source_));
    std::fflush(stdout);
  }
  lastPresentUs_ = now;
  if (source_ != Source::kAuto) return;
  probeSwapUs_.push_back(swapUs);
  if ((int)probeSwapUs_.size() >= kProbePresents) Decide();
}

void FrameScheduler::Decide() {
  std::vector<int64_t> s = probeSwapUs_;
  std::nth_element(s.begin(), s.begin() + s.size() / 2, s.end());
  swapMedianUs_ = s[s.size() / 2];
  // A swap that blocks on vblank takes a large share of the period; one that
  // only copies the back buffer (xvfb) returns in well under a quarter of it.
  if ((double)swapMedianUs_ >= 0.25 * period_ * 1e6) {
    source_ = Source::kSwapInterval;
  } else {
    source_ = Source::kSoftware;
    if (swapInterval_) swapInterval_(0);  // the clock paces; never wait twice
  }
  phaseUs_ = NowUs();
  std::printf("rn-impeller: vsync source=%s decided_after=%d swap_median_us=%lld\n",
              SourceName(source_), (int)probeSwapUs_.size(), (long long)swapMedianUs_);
  std::fflush(stdout);
}

void FrameScheduler::PrintSummary() const {
  std::printf("rn-impeller: frame_scheduler source=%s requests=%llu coalesced=%llu "
              "frames=%llu ticks=%llu max_frames_per_tick=%d swap_median_us=%lld\n",
              SourceName(source_), (unsigned long long)requests_.load(),
              (unsigned long long)coalesced_.load(), (unsigned long long)frames_,
              (unsigned long long)ticks_, maxFramesPerTick_, (long long)swapMedianUs_);
}

}  // namespace rni
