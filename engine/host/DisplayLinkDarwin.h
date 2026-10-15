// FP-27: darwin vsync source. Model:
// flutter/shell/platform/darwin/macos/framework/Source/FlutterDisplayLink.mm (one
// CVDisplayLink per display, the output handler on CoreVideo's thread, timestamps
// = hostTime / CVGetHostClockFrequency, period = the link's nominal output period)
// feeding FlutterVSyncWaiter.mm, whose rules live in FrameScheduler's
// kDisplayLink source (frame start = targetTimestamp - period).
// Started on FP-19's parked wip/fp-19 DisplayLinkDarwin.
#pragma once

#include <cstdint>
#include <functional>

namespace rni {

class DisplayLinkDarwin {
 public:
  // CoreVideo's thread. nowUs: when the link fired; targetUs: the vblank the
  // next frame is shown at; both on the steady clock the FrameScheduler uses.
  using Sink = std::function<void(int64_t nowUs, int64_t targetUs, int64_t periodUs)>;
  // displayId: the window's CGDirectDisplayID (0 = the active displays).
  DisplayLinkDarwin(uint32_t displayId, Sink sink);
  ~DisplayLinkDarwin();  // stops the link; no callback runs after it returns
  bool ok() const { return link_ != nullptr; }
  // CVDisplayLinkGetNominalOutputVideoRefreshPeriod (0 = unknown).
  int64_t nominalPeriodUs() const;

  // mach host time (CACurrentMediaTime seconds) -> steady clock us.
  static int64_t HostSecondsToSteadyUs(double hostSeconds);

 private:
  void* link_ = nullptr;  // CVDisplayLinkRef
  Sink sink_;
};

}  // namespace rni
