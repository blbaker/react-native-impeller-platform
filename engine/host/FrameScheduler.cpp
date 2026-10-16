// FP-11: see FrameScheduler.h. Model: flutter/shell/common/animator.cc and
// shell/common/vsync_waiter_fallback.cc; FP-27 kDisplayLink:
// shell/platform/darwin/macos/framework/Source/FlutterVSyncWaiter.mm.
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
      phaseUs_(NowUs()),
      displayHandle_(std::make_shared<DisplayHandle>()) {
  displayHandle_->scheduler = this;
  // kAuto probes with swap interval 1: a platform that honours it blocks in
  // the swap and keeps that source; one that does not gets the software clock.
  const Source src = options.source;
  const int interval = src == Source::kFree || src == Source::kSoftware ? 0 : 1;
  if (swapInterval_ && src != Source::kPlatform) swapInterval_(interval);
  std::printf("rn-impeller: vsync requested=%s swap_interval=%d period_us=%lld\n",
              SourceName(src), interval, (long long)(period_ * 1e6));
  std::fflush(stdout);
}

FrameScheduler::~FrameScheduler() {
  std::lock_guard<std::mutex> lock(displayHandle_->mu);
  displayHandle_->scheduler = nullptr;
}

bool FrameScheduler::ParseSource(const char* text, Source* out) {
  if (!std::strcmp(text, "auto")) *out = Source::kAuto;
  else if (!std::strcmp(text, "swap")) *out = Source::kSwapInterval;
  else if (!std::strcmp(text, "software")) *out = Source::kSoftware;
  else if (!std::strcmp(text, "off")) *out = Source::kFree;
  else if (!std::strcmp(text, "platform")) *out = Source::kPlatform;
  else if (!std::strcmp(text, "displaylink")) *out = Source::kDisplayLink;
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
    case Source::kDisplayLink: return "displaylink";
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
  const Source src = source();
  int64_t targetUs = 0;
  if (src == Source::kDisplayLink && AwaitDisplayLink()) {
    targetUs = linkTargetUs_.load(std::memory_order_acquire);
  } else if (src == Source::kSoftware || src == Source::kDisplayLink) {
    if (src == Source::kDisplayLink) ++linkFallbacks_;
    AwaitSoftwareTick();
  }
  ++ticks_;
  tickUs_ = NowUs();
  targetUs_ = targetUs ? targetUs : tickUs_.load() + (int64_t)(period_ * 1e6);
  framesThisTick_ = 1;
  maxFramesPerTick_ = std::max(maxFramesPerTick_, 1);
  burst_ = std::max(0, pending_.load(std::memory_order_acquire) - 1);
}

namespace {
// Park in the event wait (input still dispatches) until ~1.5 ms before
// `deadline`, then sleep the rest: the event wait has ms granularity.
void WaitUntil(int64_t deadline, const FrameScheduler::WaitFn& wait) {
  for (;;) {
    const int64_t rem = deadline - NowUs();
    if (rem <= 0) return;
    if (rem > 2000 && wait) wait((double)(rem - 1500) / 1e6);
    else std::this_thread::sleep_for(std::chrono::microseconds(rem));
  }
}
// FlutterVSyncWaiter.mm kTimerLatencyCompensation.
constexpr int64_t kTimerLatencyCompensationUs = 1000;
}  // namespace

void FrameScheduler::AwaitSoftwareTick() {
  TRACE_EVENT0("frame", "AwaitVsync");
  const int64_t interval = (int64_t)(period_ * 1e6);
  WaitUntil(SnapToNextTick(NowUs(), phaseUs_.load(), interval), wait_);
}

bool FrameScheduler::AwaitDisplayLink() {
  TRACE_EVENT0("frame", "AwaitDisplayLink");
  // waitForVSync: no callback yet = the synthesized initial vsync (a timer).
  const uint64_t seen = linkSeq_.load(std::memory_order_acquire);
  if (seen == 0) return false;
  // The request is the pending baton; the next callback serves it.
  const int64_t giveUp = NowUs() + 4 * (int64_t)(period_ * 1e6);
  linkWaiting_.store(true, std::memory_order_release);
  while (linkSeq_.load(std::memory_order_acquire) == seen) {
    const int64_t rem = giveUp - NowUs();
    if (rem <= 0) break;
    if (wait_) wait_((double)rem / 1e6);
    else std::this_thread::sleep_for(std::chrono::microseconds(std::min<int64_t>(rem, 1000)));
  }
  linkWaiting_.store(false, std::memory_order_release);
  if (linkSeq_.load(std::memory_order_acquire) == seen) return false;  // link stalled
  // onDisplayLink: the callback runs ~1.5 frames before targetTimestamp, so the
  // frame starts at minStart = target - period (timer fired 1 ms early).
  const int64_t target = linkTargetUs_.load(std::memory_order_acquire);
  const int64_t minStart = target - linkPeriodUs_.load(std::memory_order_acquire);
  WaitUntil(minStart - kTimerLatencyCompensationUs, wait_);
  ++linkTicks_;
  return true;
}

void FrameScheduler::OnDisplayLink(int64_t nowUs, int64_t targetUs, int64_t periodUs) {
  if (periodUs > 0) linkPeriodUs_.store(periodUs, std::memory_order_release);
  linkTargetUs_.store(targetUs, std::memory_order_release);
  phaseUs_.store(targetUs, std::memory_order_release);  // the fallback grid stays on the vblanks
  const uint64_t n = linkSeq_.fetch_add(1, std::memory_order_acq_rel) + 1;
  if (options_.log) {
    std::printf("rn-impeller: display_link_tick n=%llu t_us=%lld target_us=%lld period_us=%lld\n",
                (unsigned long long)n, (long long)nowUs, (long long)targetUs, (long long)periodUs);
    std::fflush(stdout);
  }
  if (linkWaiting_.load(std::memory_order_acquire) && wake_) wake_();
}

void FrameScheduler::DidDisplay(int presentNumber, int64_t presentedUs, int64_t encodeUs,
                                int64_t vsyncUs, int64_t targetUs) {
  // Serialized by the caller's DisplayHandle lock.
  if (presentedUs <= 0) {
    dropped_.fetch_add(1, std::memory_order_relaxed);
  } else {
    displayed_.fetch_add(1, std::memory_order_relaxed);
  }
  if (!options_.log) {
    if (presentedUs > 0) lastDisplayedUs_ = presentedUs;
    return;
  }
  std::printf("rn-impeller: vsync_displayed n=%d presented_us=%lld encode_us=%lld tick_us=%lld "
              "target_us=%lld\n",
              presentNumber, (long long)presentedUs, (long long)encodeUs, (long long)vsyncUs,
              (long long)targetUs);
  if (presentedUs > 0) {
    std::printf("rn-impeller: vsync_present n=%d t_us=%lld swap_us=%lld interval_us=%lld "
                "since_vsync_us=%lld source=%s\n",
                presentNumber, (long long)presentedUs, (long long)(presentedUs - encodeUs),
                (long long)(lastDisplayedUs_ ? presentedUs - lastDisplayedUs_ : 0),
                (long long)(presentedUs - vsyncUs), SourceName(source()));
    lastDisplayedUs_ = presentedUs;
  }
  std::fflush(stdout);
}

uint64_t FrameScheduler::BeginFrame() {
  if (pending_.load(std::memory_order_acquire) > 0) {
    pending_.fetch_sub(1, std::memory_order_acq_rel);
  }
  return ++frames_;
}

void FrameScheduler::WillPresent() { presentStartUs_ = NowUs(); }

void FrameScheduler::DidPresent(int presentNumber, int64_t vsyncUs) {
  if (source() == Source::kDisplayLink) return;  // DidDisplay logs at presentedTime
  const int64_t now = NowUs();
  const int64_t swapUs = now - presentStartUs_;
  const int64_t tick = vsyncUs > 0 ? vsyncUs : tickUs_.load();
  if (options_.log) {
    std::printf("rn-impeller: vsync_present n=%d t_us=%lld swap_us=%lld "
                "interval_us=%lld since_vsync_us=%lld source=%s\n",
                presentNumber, (long long)now, (long long)swapUs,
                (long long)(lastPresentUs_ ? now - lastPresentUs_ : 0),
                (long long)(now - tick), SourceName(source()));
    std::fflush(stdout);
  }
  lastPresentUs_ = now;
  if (source() != Source::kAuto) return;
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
              SourceName(source()), (int)probeSwapUs_.size(), (long long)swapMedianUs_);
  std::fflush(stdout);
}

void FrameScheduler::PrintSummary() const {
  std::printf("rn-impeller: frame_scheduler source=%s requests=%llu coalesced=%llu "
              "frames=%llu ticks=%llu max_frames_per_tick=%d swap_median_us=%lld\n",
              SourceName(source()), (unsigned long long)requests_.load(),
              (unsigned long long)coalesced_.load(), (unsigned long long)frames_,
              (unsigned long long)ticks_, maxFramesPerTick_, (long long)swapMedianUs_);
  if (source() == Source::kDisplayLink) {
    std::printf("rn-impeller: display_link callbacks=%llu link_ticks=%llu fallback_ticks=%llu "
                "displayed=%d dropped=%d\n",
                (unsigned long long)linkSeq_.load(), (unsigned long long)linkTicks_,
                (unsigned long long)linkFallbacks_, displayed_.load(), dropped_.load());
  }
}

}  // namespace rni
