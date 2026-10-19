// iOS Phase 1 / Task 1.2: iOS vsync source, the counterpart of
// DisplayLinkDarwin (FP-27) with the same Sink contract. CVDisplayLink is
// macOS-only; iOS has CADisplayLink, which fires on the run loop it is added
// to. Model: flutter/shell/platform/darwin/ios/framework/Source/vsync_waiter_ios.mm
// (CADisplayLink on the UI thread's run loop in NSRunLoopCommonModes so it
// keeps firing during scroll tracking; timestamp = the vblank that just
// happened, targetTimestamp = the one the next frame is shown at).
#pragma once

#include <cstdint>
#include <functional>

namespace rni {

class DisplayLinkIOS {
 public:
  // Main thread (the link's run loop). nowUs: CADisplayLink.timestamp;
  // targetUs: targetTimestamp; periodUs: targetUs - nowUs. All on the steady
  // clock the FrameScheduler uses.
  using Sink = std::function<void(int64_t nowUs, int64_t targetUs, int64_t periodUs)>;
  // Main thread. Creates the link and adds it to the main run loop in
  // NSRunLoopCommonModes.
  explicit DisplayLinkIOS(Sink sink);
  ~DisplayLinkIOS();  // main thread: invalidates; no callback runs after it returns
  bool ok() const { return link_ != nullptr; }
  // 1 / UIScreen.maximumFramesPerSecond until the link has fired, then the
  // last measured targetTimestamp - timestamp (0 = unknown).
  int64_t nominalPeriodUs() const;
  // Main thread. CADisplayLink.paused.
  void SetPaused(bool paused);

  // mach host time (CACurrentMediaTime seconds) -> steady clock us.
  static int64_t HostSecondsToSteadyUs(double hostSeconds);

 private:
  void* link_ = nullptr;    // CADisplayLink, retained
  void* target_ = nullptr;  // RNIDisplayLinkTarget, retained
  Sink sink_;
};

}  // namespace rni
