// FP-40: RN's declarative LayoutAnimation (LayoutAnimation.configureNext).
//
// Owns RN's own C++ LayoutAnimationDriver (a LayoutAnimationKeyFrameManager),
// which is BOTH the Scheduler's UIManagerAnimationDelegate and every surface's
// MountingOverrideDelegate, exactly as RN Android wires it
// (ReactAndroid/.../fabric/FabricUIManagerBinding.cpp: animationDriver_,
// setMountingOverrideDelegate after surfaceHandler.start(), driveCxxAnimations
// -> Scheduler::animationTick from the Choreographer) and RN iOS
// (React/Fabric/RCTScheduler.mm: _animationDriver + a main run-loop observer
// that is enabled by onAnimationStarted).
//
// The host drives Tick() once per frame on the platform (frame-loop) thread,
// right after FrameScheduler::BeginFrame, the way Flutter's Animator::BeginFrame
// fans out to OnAnimatorBeginFrame before the frame is built
// (shell/common/animator.cc:61-118). Tick re-pulls each surface's mounting
// coordinator; while an animation is in flight the KFM's override manufactures
// a transaction of interpolated mutations, which the SchedulerDelegate mounts.
//
// ⛔ Mount ordering. Fabric commits pull on the JS thread and ticks pull on the
// platform thread. MountingCoordinator's mutex orders the PULLS but not the
// applyMutations that follow them, so two pulls could mount out of order. Every
// pull+apply therefore runs under MountMutex(), and so does every read of the
// KFM's in-flight list (shouldAnimateFrame reads inflightAnimations_, which RN
// only protects by "mutate it inside pullTransaction").
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>

#include <ReactCommon/RuntimeExecutor.h>
#include <react/renderer/uimanager/LayoutAnimationStatusDelegate.h>

namespace facebook::react {
class ContextContainer;
class LayoutAnimationDriver;
class SurfaceHandler;
class UIManager;
class UIManagerAnimationDelegate;
}  // namespace facebook::react

namespace rni {

class LayoutAnimations final : public facebook::react::LayoutAnimationStatusDelegate {
 public:
  LayoutAnimations(facebook::react::RuntimeExecutor runtimeExecutor,
                   std::shared_ptr<const facebook::react::ContextContainer> contextContainer);
  ~LayoutAnimations() override;

  facebook::react::UIManagerAnimationDelegate* AnimationDelegate();
  // Register the driver as the surface's MountingOverrideDelegate (after start()).
  void AttachSurface(const facebook::react::SurfaceHandler& surface);

  // Platform thread, once per frame. Returns true while an animation is in flight.
  bool Tick(const facebook::react::UIManager& uiManager);
  bool Active() const;

  // Called from the pulling thread when the KFM goes from 0 to N animations.
  void SetWake(std::function<void()> wake) { wake_ = std::move(wake); }
  // Milliseconds. Default: steady_clock. Headless installs a frame-counted clock.
  void SetClock(std::function<uint64_t()> nowMs);
  uint64_t NowMs() const;

  std::mutex& MountMutex() { return mountMutex_; }

  void onAnimationStarted() override;
  void onAllAnimationsComplete() override;

  void PrintSummary() const;

 private:
  std::shared_ptr<facebook::react::LayoutAnimationDriver> driver_;
  std::function<void()> wake_;
  std::function<uint64_t()> nowMs_;
  std::mutex mountMutex_;
  bool log_ = false;
  std::atomic<bool> active_{false};
  std::atomic<uint64_t> started_{0};
  std::atomic<uint64_t> completed_{0};
  uint64_t ticks_ = 0;
  uint64_t animatedTicks_ = 0;
};

}  // namespace rni
