#pragma once

// Host-side device events: the path a NON-module needs to reach JS.
//
// WHY THIS EXISTS
// TurboModule::emitDeviceEvent is the only emitter this engine had, and it is
// a protected member of TurboModule -- reachable from NetworkingModule, not
// from the window/resize code in engine/host. So native could resize the
// surface perfectly and JS would never find out, because there was no path for
// it to be told on. Measured 2026-09-09: every one of the Mac's 16 probes would
// PASS on a build where native geometry is correct and JS never hears about it
// (tools/boundary-audit.py, boundary-crossing 0/16). The defect lives at the
// language crossing, and this class is the crossing.
//
// ⛔ THE DROP LOG IS NOT OPTIONAL, IT IS THE POINT.
// RN's own TurboModule::emitDeviceEvent (TurboModule.cpp:47-60) reads
// __rctDeviceEventEmitter off the global and, if it is undefined, does
// NOTHING -- no throw, no log, no return value. So "the bundle had no emitter
// yet" and "the emitter ran and no JS listener cared" are indistinguishable
// from outside, and both look exactly like "the native side never emitted".
// Every branch here says which one happened, because the alternative is
// inferring delivery from a re-render that has three other reasons to fail.

#include <ReactCommon/RuntimeExecutor.h>
#include <folly/dynamic.h>
#include <jsi/jsi.h>
#include <jsi/JSIDynamic.h>

#include <cstdio>
#include <mutex>
#include <string>
#include <utility>

namespace rni {

class DeviceEventSink {
 public:
  DeviceEventSink() = default;

  // Installed once the instance exists. Until then emit() is a NAMED no-op
  // rather than a crash: the host publishes initial metrics before the bundle
  // is evaluated, and that call is legitimately too early to deliver.
  void setRuntimeExecutor(facebook::react::RuntimeExecutor executor) {
    std::lock_guard<std::mutex> lock(mutex_);
    executor_ = std::move(executor);
    valid_ = true;
  }

  // ⛔ CALLED FROM THE ReactHost DESTRUCTOR, UNDER THE MUTEX, BEFORE TEARDOWN.
  // The executor closes over the ReactInstance. A resize arriving on the main
  // thread while the instance is being destroyed on another would schedule
  // work against freed memory -- a use-after-free that only reproduces when a
  // window is dragged during shutdown, which is to say: never in CI, and on
  // Baker's machine.
  void invalidate() {
    std::lock_guard<std::mutex> lock(mutex_);
    valid_ = false;
    executor_ = nullptr;
  }

  // Emits `eventName` with a single folly::dynamic payload, the shape
  // RCTDeviceEventEmitter delivers to JS listeners.
  //
  // emitEvent=false records the call and delivers nothing. The initial metrics
  // publish uses it: JS has not been evaluated, so there is no listener, and a
  // "dropped" line there would be noise that trains the reader to ignore the
  // line that matters.
  void emit(const std::string& eventName,
            const folly::dynamic& payload,
            bool emitEvent = true) {
    facebook::react::RuntimeExecutor executor;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!valid_ || !executor_) {
        std::printf("DEVEVENT: %s DROPPED (no runtime executor; pre-bundle or "
                    "post-teardown)\n", eventName.c_str());
        std::fflush(stdout);
        return;
      }
      executor = executor_;
    }

    if (!emitEvent) {
      std::printf("DEVEVENT: %s suppressed (emitEvent=false)\n",
                  eventName.c_str());
      std::fflush(stdout);
      return;
    }

    executor([eventName, payload](jsi::Runtime& rt) {
      // Same global RN's own emitter uses. Reading it here rather than caching
      // a reference: the bundle can replace it, and a stale handle would
      // deliver into an emitter nothing is listening to.
      jsi::Value emitter = rt.global().getProperty(rt, "__rctDeviceEventEmitter");
      if (emitter.isUndefined() || !emitter.isObject()) {
        // THE BRANCH THAT COST THE HOUR. Native did everything right and JS
        // still never heard. Without this line the only symptom is a layout
        // that does not update, which has three other explanations.
        std::printf("DEVEVENT: %s DROPPED (__rctDeviceEventEmitter undefined; "
                    "bundle not evaluated or emitter replaced)\n",
                    eventName.c_str());
        std::fflush(stdout);
        return;
      }
      jsi::Object emitterObject = emitter.asObject(rt);
      jsi::Function emitFunction =
          emitterObject.getPropertyAsFunction(rt, "emit");
      std::vector<jsi::Value> args;
      args.emplace_back(jsi::String::createFromAscii(rt, eventName.c_str()));
      args.emplace_back(jsi::valueFromDynamic(rt, payload));
      emitFunction.callWithThis(rt, emitterObject,
                                (const jsi::Value*)args.data(), args.size());
      // DELIVERED means the emit function ran. It does NOT mean a listener
      // existed -- RCTDeviceEventEmitter.emit on an unsubscribed event is a
      // silent no-op, and no native-side check can see that. Worth saying
      // plainly so this line is not read as proof the app reacted.
      std::printf("DEVEVENT: %s delivered to __rctDeviceEventEmitter "
                  "(listener count unknown from native)\n", eventName.c_str());
      std::fflush(stdout);
    });
  }

 private:
  std::mutex mutex_;
  facebook::react::RuntimeExecutor executor_{nullptr};
  bool valid_{false};
};

}  // namespace rni
