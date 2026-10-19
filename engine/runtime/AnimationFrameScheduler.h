// AnimationFrameScheduler — requestAnimationFrame paced to the host's frames.
//
// ⛔ RN CORE'S BRIDGELESS requestAnimationFrame IS setTimeout(0).
// ReactCommon/react/runtime/TimerManager.cpp says so in a comment. A JS-driven
// Animated loop (useNativeDriver: false) therefore runs as fast as the JS
// thread can go, not once per frame: each step re-registers a 0 ms timer, and
// each step on a typing indicator is one setNativeProps commit per dot.
// Measured on Jim v5's chat screen (2026-10-19): ~1,170 frame requests/s while
// the scene lock throttled it, ~14,400/s once the paragraph cache freed the
// lock, JS thread at 88-100%. The streamed chat text starved behind it and the
// window looked frozen.
//
// This replaces the two globals (installed after TimerManager::attachGlobals,
// so ours win) with the browser contract: callbacks registered before a frame
// run ONCE, together, at the start of that frame, with one shared timestamp.
// A callback registered from inside a flush waits for the next frame.
//
// Two cadences:
//   frame  the host frame loop calls attachFrameLoop() then beginFrame() at
//          every BeginFrame. At most one flush is in flight: a busy JS thread
//          gets ONE queued flush, never a backlog, so a slow frame cannot pile
//          up animation work ahead of the JS that streams text.
//   timer  no frame loop (headless single-shot, before the loop starts, an
//          embedder with no loop): a 16 ms one-shot on the JS thread's deadline
//          heap, so rAF still fires and is still capped near 60/s.
//
// RNI_RAF_PACING=0 restores RN's setTimeout(0) behaviour (gate control arm).
#pragma once

#include <jsi/jsi.h>
#include <ReactCommon/RuntimeExecutor.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>

namespace rni {

class JsThread;

class AnimationFrameScheduler
    : public std::enable_shared_from_this<AnimationFrameScheduler> {
 public:
  // Reserved JsThread timer id for the timer cadence. TimerManager hands out
  // ids counting up from 0; this one sits at the top of the uint32 range.
  static constexpr uint32_t kTimerId = 0xFFFFFFF0u;

  explicit AnimationFrameScheduler(std::shared_ptr<JsThread> jsThread);

  // False when RNI_RAF_PACING=0: install() then leaves RN's globals alone.
  bool enabled() const { return enabled_; }

  // Buffered runtime executor (same one TimerManager uses).
  void setRuntimeExecutor(facebook::react::RuntimeExecutor executor);

  // JS thread, from the bindings install. Replaces requestAnimationFrame and
  // cancelAnimationFrame on the global object.
  void install(facebook::jsi::Runtime& runtime);

  // Frame-loop thread. After this the host owns the cadence. `wake` must be
  // safe from any thread; it asks a sleeping loop for a frame.
  void attachFrameLoop(std::function<void()> wake);
  // Frame-loop thread, once per frame at BeginFrame.
  void beginFrame();

  // JS thread: the reserved timer fired (timer cadence).
  void onTimer();

  // One summary line for gates.
  std::string summary() const;

  // JS thread, at teardown BEFORE the runtime goes: drops every held
  // jsi::Function (their destructors call into the runtime that made them).
  void releaseCallbacks();

 private:
  int request(facebook::jsi::Runtime& rt, facebook::jsi::Function fn);
  void cancel(int id);
  void postFlush();
  void flush(facebook::jsi::Runtime& rt);

  std::shared_ptr<JsThread> jsThread_;
  facebook::react::RuntimeExecutor executor_;
  bool enabled_{true};

  // JS thread only.
  std::map<int, std::shared_ptr<facebook::jsi::Function>> pending_;
  std::map<int, std::shared_ptr<facebook::jsi::Function>> running_;
  int nextId_{1};
  bool timerArmed_{false};

  // Cross-thread.
  std::atomic<bool> attached_{false};
  std::atomic<bool> havePending_{false};
  std::atomic<bool> inFlight_{false};
  std::mutex wakeMutex_;
  std::function<void()> wake_;

  std::atomic<unsigned long> requests_{0};
  std::atomic<unsigned long> flushes_{0};
  std::atomic<unsigned long> callbacksRun_{0};
  std::atomic<unsigned long> frameFlushes_{0};
  std::atomic<unsigned long> timerFlushes_{0};
};

}  // namespace rni
