// AnimationFrameScheduler — see the header for why this exists.
#include "runtime/AnimationFrameScheduler.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <utility>
#include <vector>

#include "runtime/JsThread.h"

namespace jsi = facebook::jsi;

namespace rni {

namespace {
// 60 Hz. Only the TIMER cadence uses it; under a frame loop the display's own
// rate (60, 120, whatever presents) sets the pace.
constexpr double kTimerCadenceMs = 16.0;

bool pacingEnabledFromEnv() {
  const char* v = std::getenv("RNI_RAF_PACING");
  return !(v != nullptr && std::strcmp(v, "0") == 0);
}
}  // namespace

AnimationFrameScheduler::AnimationFrameScheduler(
    std::shared_ptr<JsThread> jsThread)
    : jsThread_(std::move(jsThread)), enabled_(pacingEnabledFromEnv()) {}

void AnimationFrameScheduler::setRuntimeExecutor(
    facebook::react::RuntimeExecutor executor) {
  executor_ = std::move(executor);
}

void AnimationFrameScheduler::install(jsi::Runtime& runtime) {
  if (!enabled_) return;
  std::weak_ptr<AnimationFrameScheduler> weak = weak_from_this();
  runtime.global().setProperty(
      runtime, "requestAnimationFrame",
      jsi::Function::createFromHostFunction(
          runtime, jsi::PropNameID::forAscii(runtime, "requestAnimationFrame"),
          1,
          [weak](jsi::Runtime& rt, const jsi::Value&, const jsi::Value* args,
                 size_t count) -> jsi::Value {
            // Same argument errors as RN's TimerManager, word for word.
            if (count == 0) {
              throw jsi::JSError(
                  rt,
                  "requestAnimationFrame must be called with at least one argument (i.e: a callback)");
            }
            if (!args[0].isObject() || !args[0].asObject(rt).isFunction(rt)) {
              throw jsi::JSError(
                  rt, "The first argument to requestAnimationFrame must be a function.");
            }
            auto self = weak.lock();
            if (!self) return jsi::Value(0);
            return jsi::Value(
                self->request(rt, args[0].getObject(rt).getFunction(rt)));
          }));
  runtime.global().setProperty(
      runtime, "cancelAnimationFrame",
      jsi::Function::createFromHostFunction(
          runtime, jsi::PropNameID::forAscii(runtime, "cancelAnimationFrame"),
          1,
          [weak](jsi::Runtime&, const jsi::Value&, const jsi::Value* args,
                 size_t count) -> jsi::Value {
            if (count > 0 && args[0].isNumber()) {
              if (auto self = weak.lock()) {
                self->cancel(static_cast<int>(args[0].asNumber()));
              }
            }
            return jsi::Value::undefined();
          }));
}

// JS thread.
int AnimationFrameScheduler::request(jsi::Runtime&, jsi::Function fn) {
  const int id = nextId_++;
  pending_.emplace(id, std::make_shared<jsi::Function>(std::move(fn)));
  requests_.fetch_add(1, std::memory_order_relaxed);
  havePending_.store(true);
  if (attached_.load()) {
    // The loop may be asleep (idle-skip). A flush already in flight re-wakes
    // at its end if anything is still pending, so one wake per gap suffices.
    if (!inFlight_.load()) {
      std::lock_guard<std::mutex> lock(wakeMutex_);
      if (wake_) wake_();
    }
  } else if (!timerArmed_) {
    timerArmed_ = true;
    jsThread_->scheduleTimer(kTimerId, kTimerCadenceMs, false);
  }
  return id;
}

// JS thread.
void AnimationFrameScheduler::cancel(int id) {
  if (id <= 0) return;  // web spec: negative/zero handles are a no-op
  pending_.erase(id);
  running_.erase(id);
}

void AnimationFrameScheduler::attachFrameLoop(std::function<void()> wake) {
  {
    std::lock_guard<std::mutex> lock(wakeMutex_);
    wake_ = std::move(wake);
  }
  attached_.store(true);
  // Anything registered under the timer cadence is flushed by the next
  // beginFrame (or by the timer already armed, whichever comes first).
  if (havePending_.load()) {
    std::lock_guard<std::mutex> lock(wakeMutex_);
    if (wake_) wake_();
  }
}

// Frame-loop thread.
void AnimationFrameScheduler::beginFrame() {
  if (!enabled_ || !havePending_.load()) return;
  // ⛔ AT MOST ONE FLUSH IN FLIGHT. If the JS thread has not run the last one
  // yet, this frame posts nothing: queueing a second would hand a busy JS
  // thread a backlog of animation steps ahead of everything else it owes.
  if (inFlight_.exchange(true)) return;
  frameFlushes_.fetch_add(1, std::memory_order_relaxed);
  postFlush();
}

// JS thread (JsThread timer fire callback).
void AnimationFrameScheduler::onTimer() {
  timerArmed_ = false;
  if (!havePending_.load()) return;
  if (inFlight_.exchange(true)) return;
  timerFlushes_.fetch_add(1, std::memory_order_relaxed);
  postFlush();
}

void AnimationFrameScheduler::postFlush() {
  if (!executor_) {
    inFlight_.store(false);
    return;
  }
  std::weak_ptr<AnimationFrameScheduler> weak = weak_from_this();
  executor_([weak](jsi::Runtime& rt) {
    if (auto self = weak.lock()) self->flush(rt);
  });
}

// JS thread.
void AnimationFrameScheduler::flush(jsi::Runtime& rt) {
  // Swap first: callbacks registered while these run belong to the NEXT
  // frame (browser semantics). The batch lives in running_ so a cancel of a
  // callback later in this same batch still takes effect.
  running_.clear();
  running_.swap(pending_);
  havePending_.store(false);
  flushes_.fetch_add(1, std::memory_order_relaxed);

  // One timestamp for the whole batch, read the way RN's rAF reads it.
  jsi::Value now = jsi::Value(0.0);
  {
    auto performance = rt.global().getPropertyAsObject(rt, "performance");
    auto nowFn = performance.getPropertyAsFunction(rt, "now");
    now = nowFn.callWithThis(rt, performance, {});
  }

  // A throwing callback must not swallow the rest of the frame, and must not
  // be swallowed itself: run them all, then rethrow the first error so RN's
  // error handler reports it exactly as it would have.
  std::exception_ptr firstError;
  while (!running_.empty()) {
    auto it = running_.begin();
    std::shared_ptr<jsi::Function> fn = std::move(it->second);
    running_.erase(it);
    try {
      fn->call(rt, now);
      callbacksRun_.fetch_add(1, std::memory_order_relaxed);
    } catch (...) {
      if (!firstError) firstError = std::current_exception();
    }
  }

  inFlight_.store(false);
  if (havePending_.load()) {
    if (attached_.load()) {
      std::lock_guard<std::mutex> lock(wakeMutex_);
      if (wake_) wake_();
    } else if (!timerArmed_) {
      timerArmed_ = true;
      jsThread_->scheduleTimer(kTimerId, kTimerCadenceMs, false);
    }
  }
  if (firstError) std::rethrow_exception(firstError);
}

void AnimationFrameScheduler::releaseCallbacks() {
  pending_.clear();
  running_.clear();
  havePending_.store(false);
}

std::string AnimationFrameScheduler::summary() const {
  char buf[256];
  std::snprintf(buf, sizeof buf,
                "raf_pacing enabled=%d mode=%s requests=%lu flushes=%lu "
                "frame_flushes=%lu timer_flushes=%lu callbacks=%lu",
                enabled_ ? 1 : 0, attached_.load() ? "frame" : "timer",
                requests_.load(), flushes_.load(), frameFlushes_.load(),
                timerFlushes_.load(), callbacksRun_.load());
  return buf;
}

}  // namespace rni
