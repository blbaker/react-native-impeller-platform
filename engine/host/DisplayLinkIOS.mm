// iOS Phase 1 / Task 1.2: see DisplayLinkIOS.h. Built with -fobjc-arc.
#include "host/DisplayLinkIOS.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <atomic>
#include <chrono>

static_assert(__has_feature(objc_arc), "DisplayLinkIOS.mm must be built with -fobjc-arc");

// CADisplayLink retains its target, so the target holds only a raw pointer to
// the owner's sink and is cut loose (sink = nullptr) before the owner dies.
@interface RNIDisplayLinkTarget : NSObject {
 @public
  const rni::DisplayLinkIOS::Sink* sink;
  std::atomic<int64_t> lastPeriodUs;
}
- (void)onDisplayLink:(CADisplayLink*)link;
@end

@implementation RNIDisplayLinkTarget
- (void)onDisplayLink:(CADisplayLink*)link {
  if (!sink) return;
  const int64_t nowUs = rni::DisplayLinkIOS::HostSecondsToSteadyUs(link.timestamp);
  const int64_t targetUs = rni::DisplayLinkIOS::HostSecondsToSteadyUs(link.targetTimestamp);
  const int64_t periodUs = targetUs > nowUs ? targetUs - nowUs : 0;
  if (periodUs > 0) lastPeriodUs.store(periodUs, std::memory_order_relaxed);
  (*sink)(nowUs, targetUs, periodUs);
}
@end

namespace rni {

int64_t DisplayLinkIOS::HostSecondsToSteadyUs(double hostSeconds) {
  const int64_t steadyNowUs = std::chrono::duration_cast<std::chrono::microseconds>(
                                  std::chrono::steady_clock::now().time_since_epoch())
                                  .count();
  return steadyNowUs + (int64_t)((hostSeconds - CACurrentMediaTime()) * 1e6);
}

DisplayLinkIOS::DisplayLinkIOS(Sink sink) : sink_(std::move(sink)) {
  RNIDisplayLinkTarget* target = [RNIDisplayLinkTarget new];
  target->sink = &sink_;
  target->lastPeriodUs.store(0);
  CADisplayLink* link = [CADisplayLink displayLinkWithTarget:target
                                                    selector:@selector(onDisplayLink:)];
  if (!link) return;
  [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  link_ = (__bridge_retained void*)link;
  target_ = (__bridge_retained void*)target;
}

DisplayLinkIOS::~DisplayLinkIOS() {
  if (target_) {
    RNIDisplayLinkTarget* target = (__bridge_transfer RNIDisplayLinkTarget*)target_;
    target->sink = nullptr;
    target_ = nullptr;
  }
  if (link_) {
    CADisplayLink* link = (__bridge_transfer CADisplayLink*)link_;
    [link invalidate];  // removes it from every run loop; main thread, so no callback is mid-flight
    link_ = nullptr;
  }
}

int64_t DisplayLinkIOS::nominalPeriodUs() const {
  if (!link_) return 0;
  RNIDisplayLinkTarget* target = (__bridge RNIDisplayLinkTarget*)target_;
  const int64_t measured = target ? target->lastPeriodUs.load(std::memory_order_relaxed) : 0;
  if (measured > 0) return measured;
  const NSInteger fps = UIScreen.mainScreen.maximumFramesPerSecond;
  return fps > 0 ? 1000000 / fps : 0;
}

void DisplayLinkIOS::SetPaused(bool paused) {
  if (link_) ((__bridge CADisplayLink*)link_).paused = paused;
}

}  // namespace rni
