// FP-40: see LayoutAnimations.h.
#include "fabric/LayoutAnimations.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <react/renderer/animations/LayoutAnimationDriver.h>
#include <react/renderer/mounting/ShadowTree.h>
#include <react/renderer/scheduler/SurfaceHandler.h>
#include <react/renderer/uimanager/UIManager.h>

#include "base/Trace.h"

namespace react = facebook::react;

namespace rni {

namespace {
uint64_t SteadyNowMs() {
  return static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now().time_since_epoch())
          .count());
}
}  // namespace

LayoutAnimations::LayoutAnimations(
    react::RuntimeExecutor runtimeExecutor,
    std::shared_ptr<const react::ContextContainer> contextContainer) {
  const char* log = std::getenv("RNI_LAYOUT_ANIM_LOG");
  log_ = log != nullptr && std::strcmp(log, "0") != 0;
  driver_ = std::make_shared<react::LayoutAnimationDriver>(
      std::move(runtimeExecutor), contextContainer, this);
  SetClock(&SteadyNowMs);
}

LayoutAnimations::~LayoutAnimations() {
  // RCTScheduler dealloc does the same: no status callback into a dead host.
  driver_->setLayoutAnimationStatusDelegate(nullptr);
}

react::UIManagerAnimationDelegate* LayoutAnimations::AnimationDelegate() {
  return driver_.get();
}

void LayoutAnimations::AttachSurface(const react::SurfaceHandler& surface) {
  surface.getMountingCoordinator()->setMountingOverrideDelegate(driver_);
}

void LayoutAnimations::SetClock(std::function<uint64_t()> nowMs) {
  nowMs_ = nowMs;
  driver_->setClockNow(std::move(nowMs));
}

uint64_t LayoutAnimations::NowMs() const { return nowMs_(); }

bool LayoutAnimations::Active() const { return active_.load(); }

// UIManager::animationTick's LayoutAnimation half. Scheduler::animationTick is
// NOT called: its other half runs NativeAnimated's onRender, which the host
// already runs once per frame through NativeAnimatedPump (FP-10); calling both
// would step every native animation twice per frame.
bool LayoutAnimations::Tick(const react::UIManager& uiManager) {
  ++ticks_;
  bool animating = false;
  {
    std::lock_guard<std::mutex> lock(mountMutex_);
    animating = driver_->shouldAnimateFrame();
  }
  if (!animating) return false;
  ++animatedTicks_;
  TRACE_EVENT0("animated", "LayoutAnimationTick");
  if (log_) {
    std::printf("rn-impeller: layout_anim_tick n=%llu t_ms=%llu\n",
                (unsigned long long)animatedTicks_,
                (unsigned long long)NowMs());
    std::fflush(stdout);
  }
  // Each tree re-notifies with mountSynchronously=true, so the delegate pulls
  // (and the KFM override interpolates) right here on the platform thread.
  uiManager.getShadowTreeRegistry().enumerate(
      [](const react::ShadowTree& shadowTree, bool&) {
        shadowTree.notifyDelegatesOfUpdates();
      });
  return true;
}

void LayoutAnimations::onAnimationStarted() {
  active_ = true;
  ++started_;
  if (log_) {
    std::printf("rn-impeller: layout_anim_started t_ms=%llu\n",
                (unsigned long long)NowMs());
    std::fflush(stdout);
  }
  if (wake_) wake_();
}

void LayoutAnimations::onAllAnimationsComplete() {
  active_ = false;
  ++completed_;
  if (log_) {
    std::printf("rn-impeller: layout_anim_complete t_ms=%llu\n",
                (unsigned long long)NowMs());
    std::fflush(stdout);
  }
}

void LayoutAnimations::PrintSummary() const {
  std::printf(
      "rn-impeller: layout_animation started=%llu completed=%llu ticks=%llu "
      "animated_ticks=%llu\n",
      (unsigned long long)started_.load(), (unsigned long long)completed_.load(),
      (unsigned long long)ticks_, (unsigned long long)animatedTicks_);
  std::fflush(stdout);
}

}  // namespace rni
