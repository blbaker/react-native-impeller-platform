// ReactHost — owns the bridgeless ReactInstance: Hermes runtime, JS thread,
// timers, TurboModule provider, bundle load.
//
// It does NOT own Fabric or rendering. FabricHost consumes the RuntimeScheduler
// and RuntimeExecutor this exposes, so the "can JS run" and "can pixels appear"
// questions stay separately answerable.
#pragma once

#include <react/renderer/runtimescheduler/RuntimeScheduler.h>
#include <react/runtime/ReactInstance.h>

#include <memory>
#include <string>

#include "modules/CoreModules.h"
#include "modules/ModuleRegistry.h"
#include "modules/NetworkingModule.h"
#include "modules/PlatformModules.h"
#include "modules/AppStorageModule.h"
#include "runtime/DeviceEventSink.h"
#include "runtime/JsThread.h"

namespace rni {

class ReactHost {
 public:
  ReactHost();
  ~ReactHost();

  // Evaluates `source` as the app bundle. sourceURL is what SourceCode reports.
  void runScript(std::string source, const std::string& sourceURL);
  bool loadBundleFromFile(const std::string& bundlePath);

  facebook::react::ReactInstance& instance() { return *instance_; }
  std::shared_ptr<facebook::react::RuntimeScheduler> runtimeScheduler() {
    return instance_->getRuntimeScheduler();
  }
  // UNBUFFERED executor. Fabric's Scheduler installs UIManagerBinding through
  // toolbox.bridgelessBindingsExecutor and must not be queued behind the
  // buffered one, or the binding lands after JS has already asked for it.
  facebook::react::RuntimeExecutor runtimeExecutor() {
    return instance_->getUnbufferedRuntimeExecutor();
  }
  std::shared_ptr<JsThread> jsThread() { return jsThread_; }
  std::shared_ptr<DisplayMetrics> displayMetrics() { return displayMetrics_; }

  // The host-side path to JS. TurboModule::emitDeviceEvent is PROTECTED, so
  // window/resize code in engine/host had no way to tell JS anything -- native
  // could resize perfectly and the app would never hear. See DeviceEventSink.h.
  std::shared_ptr<DeviceEventSink> deviceEvents() { return deviceEvents_; }

  // The seam, exposed so the host can enumerate it (--list-modules) and so the
  // CLI can seed platform state before the bundle runs. Constructed in the
  // ctor, so these are live from the moment the host exists.
  std::shared_ptr<ModuleRegistry> modules() { return modules_; }
  std::shared_ptr<AppearanceState> appearance() { return appearance_; }
  std::shared_ptr<AlertRecord> alerts() { return alerts_; }
  std::shared_ptr<std::string> initialUrl() { return initialUrl_; }
  // ENG-04. The storage container path, resolved once by the host so the
  // module cannot relocate its own sandbox and a gate can point it at a
  // disposable directory without touching process-wide state.
  std::shared_ptr<AppStorageConfig> storage() { return storage_; }
  // Network activity, so a headless run can wait for in-flight REQUESTS and
  // not only for an idle JS thread. See NetworkActivity in NetworkingModule.h.
  std::shared_ptr<NetworkActivity> network() { return network_; }

  std::string jsThreadStats() const {
    return jsThread_ ? jsThread_->debugStats() : std::string();
  }

  // Blocks until the JS thread has no queued task and no live timer, or the
  // deadline passes. Returns true if it actually went idle. Used by the
  // headless gate so a frame is captured after JS work, not during it.
  bool waitForJsIdle(int timeoutMs);

  // Registers the names of components the engine can actually mount, so RN's
  // NativeComponentRegistry answers truthfully. Must agree with FabricHost's
  // provider registry: a component present in one and absent from the other
  // fails in a way that looks exactly like "the engine does not have it".
  void setKnownComponents(std::vector<std::string> names);

 private:
  std::shared_ptr<JsThread> jsThread_;
  std::unique_ptr<facebook::react::ReactInstance> instance_;
  std::shared_ptr<std::string> scriptURL_;
  std::shared_ptr<DisplayMetrics> displayMetrics_;
  // Constructed in the ctor, wired to the runtime executor once the instance
  // exists, and INVALIDATED in the dtor before teardown -- see ReactHost.cpp.
  std::shared_ptr<DeviceEventSink> deviceEvents_ =
      std::make_shared<DeviceEventSink>();
  std::shared_ptr<std::vector<std::string>> knownComponents_;
  std::shared_ptr<ModuleRegistry> modules_;
  std::shared_ptr<AppearanceState> appearance_;
  std::shared_ptr<AlertRecord> alerts_;
  std::shared_ptr<NetworkActivity> network_;
  std::shared_ptr<std::string> initialUrl_;
  std::shared_ptr<AppStorageConfig> storage_;
};

}  // namespace rni
