// The "Notifications" TurboModule: requestPermission() and show(), plus the
// press event, on top of the platform Backend in Notifications.h.
//
//   native  Notifications.requestPermission() -> Promise<{status, reason}>
//           Notifications.show(title, body, id, dataJson) -> Promise<{status, reason}>
//           press -> DeviceEventEmitter 'rniNotificationPress' {id, data, action}
//   JS      package/src/notifications/index.js: argument checks, the JSON
//           encoding of `data`, the onPress() subscription, and the
//           "unavailable" answer when an older engine lacks this module.
//
// ⛔ PROMISES NEVER LEAVE THE JS THREAD.
// Backends answer on their own threads (the D-Bus worker, a macOS completion
// queue). A react::Promise holds jsi::Function members, and dropping the last
// reference off the JS thread destroys JSI objects on the wrong thread. So the
// Promise stays in `pending_`, which only the JS thread touches, and the
// backend's callback carries a plain integer key and a plain Result back
// through invokeAsync. If that hop never runs (teardown), the Promise dies with
// this module on the JS side, like any other module state.
#pragma once

#include <ReactCommon/TurboModule.h>
#include <ReactCommon/TurboModuleUtils.h>

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

#include "modules/Notifications.h"

namespace rni {

namespace jsi = facebook::jsi;
namespace react = facebook::react;

// Owns the backend, created on first use so an app that never calls
// Notifications never opens a D-Bus connection or touches the macOS center.
class NotificationsService {
 public:
  explicit NotificationsService(notifications::PressSink onPress)
      : onPress_(std::move(onPress)) {}

  notifications::Backend& backend() {
    std::call_once(once_, [this] { backend_ = notifications::CreateBackend(onPress_); });
    return *backend_;
  }

 private:
  notifications::PressSink onPress_;
  std::once_flag once_;
  std::unique_ptr<notifications::Backend> backend_;
};

class NotificationsModule : public react::TurboModule {
 public:
  NotificationsModule(std::shared_ptr<react::CallInvoker> jsInvoker,
                      std::shared_ptr<NotificationsService> service)
      : react::TurboModule("Notifications", std::move(jsInvoker)),
        service_(std::move(service)) {
    methodMap_["requestPermission"] = MethodMetadata{0, requestPermissionHost};
    methodMap_["show"] = MethodMetadata{4, showHost};
  }

 private:
  struct Pending {
    std::unordered_map<uint64_t, std::shared_ptr<react::Promise>> promises;
    uint64_t next = 1;
  };

  static NotificationsModule& self(react::TurboModule& tm) {
    return static_cast<NotificationsModule&>(tm);
  }

  static jsi::Value toJs(jsi::Runtime& rt, const notifications::Result& r) {
    jsi::Object out(rt);
    out.setProperty(rt, "status", jsi::String::createFromUtf8(rt, r.status));
    if (!r.reason.empty()) {
      out.setProperty(rt, "reason", jsi::String::createFromUtf8(rt, r.reason));
    }
    return jsi::Value(rt, out);
  }

  // Parks a Promise and returns the callback that settles it from any thread.
  template <typename Start>
  jsi::Value promise(jsi::Runtime& rt, Start start) {
    auto pending = pending_;
    auto invoker = jsInvoker_;
    return react::createPromiseAsJSIValue(
        rt, [pending, invoker, start](jsi::Runtime&,
                                      std::shared_ptr<react::Promise> p) {
          const uint64_t key = pending->next++;
          pending->promises.emplace(key, std::move(p));
          std::weak_ptr<Pending> weak = pending;
          start([invoker, weak, key](notifications::Result result) {
            invoker->invokeAsync([weak, key, result = std::move(result)](
                                     jsi::Runtime& rt2) {
              auto live = weak.lock();
              if (!live) return;
              auto it = live->promises.find(key);
              if (it == live->promises.end()) return;
              auto settled = std::move(it->second);
              live->promises.erase(it);
              settled->resolve(toJs(rt2, result));
            });
          });
        });
  }

  static jsi::Value requestPermissionHost(jsi::Runtime& rt,
                                          react::TurboModule& tm,
                                          const jsi::Value*, size_t) {
    auto& me = self(tm);
    auto service = me.service_;
    return me.promise(rt, [service](notifications::Done done) {
      service->backend().requestPermission(std::move(done));
    });
  }

  // Arguments arrive pre-checked by the JS wrapper; a direct caller that skips
  // it gets an "error" result, not a thrown exception across JSI.
  static jsi::Value showHost(jsi::Runtime& rt, react::TurboModule& tm,
                             const jsi::Value* args, size_t count) {
    auto& me = self(tm);
    bool ok = count >= 4;
    for (size_t i = 0; ok && i < 4; ++i) ok = args[i].isString();
    notifications::Request request;
    if (ok) {
      request.title = args[0].asString(rt).utf8(rt);
      request.body = args[1].asString(rt).utf8(rt);
      request.id = args[2].asString(rt).utf8(rt);
      request.data = args[3].asString(rt).utf8(rt);
      ok = !request.title.empty() && !request.id.empty();
    }
    auto service = me.service_;
    return me.promise(rt, [service, ok, request](notifications::Done done) {
      if (!ok) {
        done({"error", "show(title, body, id, dataJson) wants four strings, "
                       "with a non-empty title and id"});
        return;
      }
      service->backend().show(request, std::move(done));
    });
  }

  std::shared_ptr<NotificationsService> service_;
  std::shared_ptr<Pending> pending_ = std::make_shared<Pending>();
};

}  // namespace rni
