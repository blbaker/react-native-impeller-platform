// ClipboardModule — the "Clipboard" TurboModule (NativeClipboardCxxSpec):
// getString()/setString(). See ClipboardBridge.h for the thread-safety
// design this sits on top of; this file is only the JSI/Promise surface.
//
// ⛔ FIFO ORDER THROUGH THE BRIDGE IS WHAT MAKES setString THEN getString
// RESOLVE CORRECTLY. setString posts a main-thread WRITE; getString's
// returned Promise posts a main-thread READ whose result is handed back on
// the JS thread. Both calls happen on the JS thread (TurboModule methods
// always do), so JS code that writes then reads sees its own write land in
// the queue before its own read -- the queue is drained strictly in the
// order things were posted to it.
#pragma once

#include <FBReactNativeSpecJSI.h>
#include <ReactCommon/TurboModuleUtils.h>

#include <memory>
#include <string>

#include "modules/ClipboardBridge.h"

namespace rni {

namespace jsi = facebook::jsi;
namespace react = facebook::react;

class ClipboardModule
    : public facebook::react::NativeClipboardCxxSpec<ClipboardModule> {
 public:
  ClipboardModule(std::shared_ptr<react::CallInvoker> jsInvoker,
                  std::shared_ptr<ClipboardBridge> bridge)
      : NativeClipboardCxxSpec(std::move(jsInvoker)),
        bridge_(std::move(bridge)) {}

  // No platform constants this module needs to report; present because the
  // spec requires the method (RN's NativeClipboard.js never calls it).
  jsi::Object getConstants(jsi::Runtime& rt) { return jsi::Object(rt); }

  // Returns a real Promise constructed via the global Promise constructor
  // with a host-function executor (react::createPromiseAsJSIValue, the
  // standard RN helper for exactly this shape). The EXECUTOR runs
  // synchronously on the JS thread the instant the Promise is constructed --
  // it posts the main-thread read and returns immediately; it does NOT block
  // waiting for the read.
  jsi::Value getString(jsi::Runtime& rt) {
    auto bridge = bridge_;
    auto jsInvoker = jsInvoker_;
    return react::createPromiseAsJSIValue(
        rt,
        [bridge, jsInvoker](jsi::Runtime&,
                           std::shared_ptr<react::Promise> promise) {
          // Posted to the ClipboardBridge queue (windowed) or run inline
          // (headless) -- see ClipboardBridge::postToMain. Either way this
          // body executes on the MAIN thread (windowed) or on whatever
          // thread called getString (headless, where there is no distinct
          // main thread to protect against).
          bridge->postToMain([bridge, jsInvoker, promise]() {
            std::string value = bridge->getSystemNow();
            // ⛔ HOP BACK TO THE JS THREAD TO RESOLVE, AND KEEP `promise`
            // ALIVE UNTIL THAT HOP RUNS. `promise` holds jsi::Function
            // members; those are JSI objects whose destruction touches the
            // jsi::Runtime, so they may only be dropped on the JS thread.
            // Capturing `promise` into THIS lambda (which runs on the main
            // thread) and NOT reading/writing any jsi::Value from it here is
            // what keeps that safe: the shared_ptr's refcount still touches
            // only ordinary memory. The lambda handed to invokeAsync below
            // is the one that actually calls into the runtime, and because
            // invokeAsync runs it on the JS thread, `promise`'s LAST
            // reference -- captured only by that inner lambda once this
            // outer one returns -- is dropped there, never here.
            jsInvoker->invokeAsync([promise, value](jsi::Runtime& rt2) {
              promise->resolve(jsi::String::createFromUtf8(rt2, value));
            });
          });
        });
  }

  // Posts a main-thread WRITE and returns immediately -- setString is
  // fire-and-forget per the spec (void, not a Promise). FIFO queuing is what
  // makes a subsequent getString() in the same JS turn see this value: the
  // write is queued (or, headless, already applied) before the read is ever
  // posted.
  void setString(jsi::Runtime& rt, jsi::String content) {
    auto bridge = bridge_;
    std::string value = content.utf8(rt);
    bridge->postToMain([bridge, value]() { bridge->setSystemNow(value); });
  }

 private:
  std::shared_ptr<ClipboardBridge> bridge_;
};

}  // namespace rni
