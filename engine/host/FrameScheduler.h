// FP-11: frame scheduling + explicit vsync for the windowed loop.
//
// Model: flutter/shell/common/animator.cc (RequestFrame dedupe through
// pending_frame_semaphore_, cleared at BeginFrame so a request made while a
// frame builds schedules the next one) and shell/common/vsync_waiter.cc +
// vsync_waiter_fallback.cc (one callback per vsync interval; the fallback is a
// 60 Hz software clock snapped to a fixed phase).
//
// Our loop is single-threaded (platform == UI == raster until FP-15), so the
// "post AwaitVSync to the UI runner" becomes: RequestFrame marks the one
// outstanding request and wakes the loop; the loop calls AwaitVsync() then
// BeginFrame(). No request, no frame: an idle window parks in its event wait.
//
// Vsync source per backend:
//   kSwapInterval  swap interval 1 (EGL/GLFW); the present blocks on vblank.
//   kSoftware      a 60 Hz clock, used when the platform does not block on swap
//                  (xvfb, llvmpipe). kAuto picks one of the two by measuring the
//                  swap duration of the first kProbePresents presents.
//   kFree          swap interval 0, no clock (`--vsync off`, benchmarking only).
//   kPlatform      no swap-interval call and no clock: whatever the context's
//                  default swap does (the pre-FP-11 loop). Default for bounded
//                  `--frames N` test runs, whose ms deadlines assume it.
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <vector>

namespace rni {

class FrameScheduler {
 public:
  enum class Source { kAuto, kSwapInterval, kSoftware, kFree, kPlatform };
  struct Options {
    Source source = Source::kAuto;
    double hz = 60.0;
    bool log = false;  // --vsync-log: one line per accepted request and present
  };
  // Block the loop up to `seconds`; returns early on input or a posted wake.
  using WaitFn = std::function<void(double seconds)>;
  // Wake a loop blocked in WaitFn. Any thread.
  using WakeFn = std::function<void()>;
  // Set the swap interval on the current GL context. Main thread.
  using SwapIntervalFn = std::function<void(int interval)>;

  FrameScheduler(Options options, WaitFn wait, WakeFn wake,
                 SwapIntervalFn swapInterval);

  static bool ParseSource(const char* text, Source* out);
  static const char* SourceName(Source s);

  // Any thread. Animator::RequestFrame: several calls before the next
  // BeginFrame collapse into the one outstanding request.
  void RequestFrame(const char* reason);
  bool FramePending() const;

  // Main thread. Blocks until the vsync that services the outstanding request
  // (software clock), or returns at once (the swap blocks instead).
  void AwaitVsync();
  // Main thread. Consumes the outstanding request; requests made from here on
  // schedule the next frame. Returns the 1-based BeginFrame number.
  uint64_t BeginFrame();

  // Main thread, around surface.present(). Feeds the kAuto swap probe.
  void WillPresent();
  void DidPresent(int presentNumber);

  Source source() const { return source_; }
  double periodSeconds() const { return period_; }
  // Prints `frame_scheduler source= requests= coalesced= frames= ...`.
  void PrintSummary() const;

  static constexpr int kProbePresents = 8;

 private:
  void Decide();

  Options options_;
  WaitFn wait_;
  WakeFn wake_;
  SwapIntervalFn swapInterval_;
  Source source_;
  double period_;
  int64_t phaseUs_;

  std::atomic<int> pending_{0};
  std::atomic<uint64_t> requests_{0};
  std::atomic<uint64_t> coalesced_{0};
  uint64_t frames_ = 0;
  uint64_t ticks_ = 0;
  int burst_ = 0;          // BeginFrames still owed to the last vsync tick
  int framesThisTick_ = 0;
  int maxFramesPerTick_ = 0;

  int64_t tickUs_ = 0;  // when the last AwaitVsync returned
  int64_t presentStartUs_ = 0;
  int64_t lastPresentUs_ = 0;
  std::vector<int64_t> probeSwapUs_;
  int64_t swapMedianUs_ = -1;
};

}  // namespace rni
