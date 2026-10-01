// parity item 24: React Native DevTools (Hermes debugger) over Metro.
//
// The same wiring RN's own hosts do (RCTHost.mm / ReactHostImpl.kt), built
// from RN's own C++:
//   HostTarget            -- the debuggable "page" (RN's jsinspector-modern)
//   ReactInstance         -- registers its InstanceTarget + Hermes
//                            RuntimeTarget under it (parentInspectorTarget)
//   addPage               -- lists it in getInspectorInstance()
//   InspectorPackagerConnection
//                         -- the device socket to Metro's
//                            /inspector/device; DevTools connects through it
//
// THREADING. Everything inspector-side runs on ONE serial thread (the
// "inspector queue"): the HostTarget is created, connected and destroyed
// there, the packager connection lives there, socket events are delivered
// there. A dedicated thread instead of the GLFW main thread on purpose:
// ReactInstance buffers ALL runtime work until registerInstance has run on
// the inspector queue, and the main thread is blocked in waitForJsIdle
// during boot -- a main-thread queue would deadlock startup.
#pragma once

#include <jsinspector-modern/HostTarget.h>
#include <jsinspector-modern/InspectorPackagerConnection.h>

#include <chrono>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

namespace rni {

// A serial executor with delayed tasks. Tasks posted after stop() are
// dropped (destroyed on the posting thread).
class InspectorQueue {
 public:
  InspectorQueue();
  ~InspectorQueue();
  void post(std::function<void()> fn,
            std::chrono::milliseconds delay = std::chrono::milliseconds(0));
  // Runs fn on the queue and waits. Inline if already on the queue.
  void runSync(const std::function<void()>& fn);
  bool onQueue() const;
  void stop();

 private:
  void loop();
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::multimap<std::chrono::steady_clock::time_point, std::function<void()>>
      tasks_;
  bool quit_{false};
  std::thread thread_;
};

class InspectorHost final
    : public facebook::react::jsinspector_modern::HostTargetDelegate {
 public:
  using ReloadHook = std::shared_ptr<std::function<void(const std::string&)>>;
  explicit InspectorHost(ReloadHook reload);
  ~InspectorHost() override;  // calls shutdown() if the owner did not

  facebook::react::jsinspector_modern::HostTarget* hostTarget() {
    return hostTarget_.get();
  }
  InspectorQueue& queue() { return *queue_; }

  // Opens the device socket to the Metro that served `sourceUrl`
  // (http(s)://host:port/...). No-op for any other URL.
  void connectToMetro(const std::string& sourceUrl, const std::string& appName);

  // Closes the device socket, removes the page, destroys the HostTarget, and
  // stops the queue. Call AFTER ReactInstance::unregisterFromInspector().
  void shutdown();

  // HostTargetDelegate (called on the inspector queue).
  facebook::react::jsinspector_modern::HostTargetMetadata getMetadata() override;
  void onReload(const PageReloadRequest& request) override;
  void onSetPausedInDebuggerMessage(
      const OverlaySetPausedInDebuggerMessageRequest& request) override;
  void loadNetworkResource(
      const facebook::react::jsinspector_modern::LoadNetworkResourceRequest& params,
      facebook::react::jsinspector_modern::ScopedExecutor<
          facebook::react::jsinspector_modern::NetworkRequestListener> executor)
      override;

 private:
  std::shared_ptr<InspectorQueue> queue_;
  ReloadHook reload_;
  std::shared_ptr<facebook::react::jsinspector_modern::HostTarget> hostTarget_;
  std::optional<int> pageId_;
  std::unique_ptr<facebook::react::jsinspector_modern::InspectorPackagerConnection>
      packager_;
  std::string appName_{"rn-impeller"};
  bool shutDown_{false};
};

}  // namespace rni
