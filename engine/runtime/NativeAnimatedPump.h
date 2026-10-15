// ENG-06 — NativeAnimated frame pump seam.
//
// RN's NativeAnimatedNodesManager does not own a clock. It asks the platform
// to start/stop a per-frame tick through two callbacks handed to
// NativeAnimatedNodesManagerProvider:
//
//   StartOnRenderCallback = void(std::function<void()>&& onRender, bool isAsync)
//   StopOnRenderCallback  = void(bool isAsync)
//
// This shared box is that seam. ReactHost hands the two callbacks to the
// provider (they run on whichever thread the manager is on -- usually JS, but
// startRenderCallbackIfNeeded is documented as callable from either), and the
// host's render loop calls ReactHost::pumpNativeAnimated() once per frame.
// When nothing is animating the pump is a single relaxed atomic load and
// schedules NOTHING, so an idle app pays nothing.
//
// ⛔ THE CLOCK IS THE FRAME COUNTER, NOT WALL TIME. The host loop drives this,
// so `--frames N` advances the animation deterministically: N frames is N
// ticks regardless of how fast the machine is. A wall-clock driver would make
// every animation gate a race, which is precisely the shape of flake this
// project has paid for elsewhere.
//
// ⚠️ TICKING THE PUMP IS NOT ENOUGH ON ITS OWN, AND THAT COST A WHOLE COMMIT.
// RN's animation drivers do not measure progress in ticks -- FrameAnimationDriver
// interpolates on `timeDeltaMs`, taken from NativeAnimatedNodesManager's
// `g_now()`, which defaults to steady_clock. A headless run renders ~1000fps,
// so 60 pumped frames elapse under 60 REAL milliseconds: every driver sampled
// its curve at t≈0, produced the same start value 60 times, and the animation
// was frozen while ticks read a perfect 60/60. The pump and the clock are two
// separate seams and only one of them was wired.
//
// So the host also installs a frame-counted `now` via
// g_setNativeAnimatedNowTimestampFunction (RN's own test seam): one pump call
// advances the clock by exactly one 60fps frame interval. See
// ReactHost::advanceAnimationClock().
//
// FP-10: the onRender callback runs ON THE FRAME-LOOP THREAD (RN's UI-tick
// contract), called directly by ReactHost::pumpNativeAnimated. JS-thread work
// it triggers (onEnd, value listeners, layout-prop commits) is posted to JS by
// RN itself. See ReactHost::pumpNativeAnimated for the thread-safety argument.
#pragma once

#include "base/Trace.h"
#include <atomic>
#include <chrono>
#include <functional>
#include <mutex>
#include <utility>

namespace rni {

class NativeAnimatedPump {
 public:
  // NativeAnimatedNodesManager::StartOnRenderCallback
  void start(std::function<void()>&& onRender, bool /*isAsync*/) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      onRender_ = std::move(onRender);
    }
    active_.store(true, std::memory_order_release);
  }

  // NativeAnimatedNodesManager::StopOnRenderCallback
  void stop(bool /*isAsync*/) {
    active_.store(false, std::memory_order_release);
  }

  // Cheap main-thread early-out: true only while an animation is in flight.
  bool isActive() const { return active_.load(std::memory_order_acquire); }

  // Runs the manager's onRender if still active. Call on the frame-loop thread.
  void tick() {
    if (!isActive()) {
      return;
    }
    std::function<void()> cb;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      cb = onRender_;
    }
    if (cb) {
      TRACE_EVENT0("animated", "NativeAnimatedTick");
      const auto t0 = std::chrono::steady_clock::now();
      cb();
      tickNanos_.fetch_add(
          (unsigned long long)std::chrono::duration_cast<std::chrono::nanoseconds>(
              std::chrono::steady_clock::now() - t0)
              .count(),
          std::memory_order_relaxed);
      ticks_.fetch_add(1, std::memory_order_relaxed);
    }
  }

  // Wall time spent inside onRender, summed over all ticks, in microseconds.
  // Frame-loop-thread cost of a native-driven animation; no JS executes.
  unsigned long long tickMicros() const {
    return tickNanos_.load(std::memory_order_relaxed) / 1000ULL;
  }

  // How many times the manager's onRender actually ran.
  //
  // WHY THIS EXISTS: RN's Animated silently FALLS BACK to its JS driver when
  // the native animated module is absent (shouldUseNativeDriver() returns
  // false and logs a warning), so a `useNativeDriver: true` animation that
  // visibly works is NOT evidence that THIS engine animated it. Both drivers
  // move the same pixels. A pixel-diff gate alone would stay green after the
  // entire C++ animation engine was ripped out; the tick count is the half of
  // the proof that lives on this side of the boundary.
  unsigned long ticks() const {
    return ticks_.load(std::memory_order_relaxed);
  }

 private:
  mutable std::mutex mutex_;
  std::function<void()> onRender_;
  std::atomic<bool> active_{false};
  std::atomic<unsigned long> ticks_{0};
  std::atomic<unsigned long long> tickNanos_{0};
};

}  // namespace rni
