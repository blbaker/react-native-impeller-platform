// ReactHost — owns the bridgeless ReactInstance: Hermes runtime, JS thread,
// timers, TurboModule provider, bundle load.
//
// It does NOT own Fabric or rendering. FabricHost consumes the RuntimeScheduler
// and RuntimeExecutor this exposes, so the "can JS run" and "can pixels appear"
// questions stay separately answerable.
#pragma once

#include <react/renderer/runtimescheduler/RuntimeScheduler.h>
#include <react/runtime/ReactInstance.h>

#include <functional>
#include <memory>
#include <string>

#include "modules/CoreModules.h"
#include "modules/ModuleRegistry.h"
#include "modules/NetworkingModule.h"
#include "modules/WebSocketModule.h"
#include "modules/PlatformModules.h"
#include "modules/AppStorageModule.h"
#include "modules/WorldRasterModule.h"
#include "modules/WorldRasterStore.h"
#include "modules/ClipboardBridge.h"
#include "runtime/DeviceEventSink.h"
#include "runtime/JsThread.h"
#include "runtime/NativeAnimatedPump.h"

#include <react/renderer/animated/NativeAnimatedNodesManagerProvider.h>

namespace rni {

class ReactHost {
 public:
  ReactHost();
  ~ReactHost();

  // Evaluates `source` as the app bundle. sourceURL is what SourceCode reports.
  void runScript(std::string source, const std::string& sourceURL);
  bool loadBundleFromFile(const std::string& bundlePath);
  // parity item 14. After runScript with an http:// source URL: start Metro
  // HMR (HMRClient.setup), as RCTDevSettings does on iOS. No-op for file://.
  void devServerSetup(const std::string& sourceUrl);
  // parity item 14. Host hook DevSettings.reload calls (thread: JS).
  void setReloadHook(std::function<void(const std::string&)> hook) {
    *reloadHook_ = std::move(hook);
  }

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
  // ENG-09. SceneGraph's world painter reads this by node name on every
  // paint; exposed so the fabric/painter side can be wired to the SAME
  // store the TurboModule writes into, rather than each owning its own.
  std::shared_ptr<rni::WorldRasterStore> worldRasterStore() {
    return worldRasterStore_;
  }
  // Network activity, so a headless run can wait for in-flight REQUESTS and
  // not only for an idle JS thread. See NetworkActivity in NetworkingModule.h.
  std::shared_ptr<NetworkActivity> network() { return network_; }
  // item 5. The thread-safe clipboard bridge: the "Clipboard" TurboModule
  // posts through it, and main.cpp wires its system backend to the real
  // GLFW clipboard once a window exists. See ClipboardBridge.h.
  std::shared_ptr<ClipboardBridge> clipboard() { return clipboard_; }

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

  // ENG-06. One NativeAnimated tick, driven by the host's frame loop so the
  // clock IS the frame counter and `--frames N` is deterministic. Safe and
  // near-free to call every frame: a relaxed atomic load when nothing is
  // animating. Hops to the JS thread itself -- call it from the render loop.
  void pumpNativeAnimated();

  // How many times RN's animation engine actually ran, for gates. See
  // NativeAnimatedPump.h for why a pixel diff alone cannot prove ENG-06.
  unsigned long nativeAnimatedTicks() const;

  // ENG-06. Replace RN's animation clock with a FRAME COUNTER, and step it.
  //
  // Ticking the pump alone is not enough: RN's drivers interpolate on elapsed
  // milliseconds read from a global `g_now`, so on a ~1000fps headless loop all
  // 60 frames sample the curve at t≈0 and the animation is frozen while the
  // tick count looks perfect. Install this before the frame loop; the pump
  // advances it. See ReactHost.cpp for the one-clock-per-process caveat.
  static void installFrameCountedAnimationClock();
  static void advanceAnimationClock();

 private:
  std::shared_ptr<JsThread> jsThread_;
  std::unique_ptr<facebook::react::ReactInstance> instance_;
  std::shared_ptr<std::string> scriptURL_;
  // parity item 14: DevSettings.reload calls this (set by the host).
  std::shared_ptr<std::function<void(const std::string&)>> reloadHook_ =
      std::make_shared<std::function<void(const std::string&)>>();
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
  std::shared_ptr<ClipboardBridge> clipboard_ =
      std::make_shared<ClipboardBridge>();
  std::shared_ptr<AppStorageConfig> storage_;
  std::shared_ptr<rni::WorldRasterStore> worldRasterStore_ =
      std::make_shared<rni::WorldRasterStore>();
  // ENG-06. The provider owns the NativeAnimatedNodesManager; the pump is the
  // clock the manager does not have. Both outlive the module, which is created
  // lazily by the registry on first JS access.
  std::shared_ptr<NativeAnimatedPump> nativeAnimatedPump_;
  std::shared_ptr<facebook::react::NativeAnimatedNodesManagerProvider>
      nativeAnimatedProvider_;
};

}  // namespace rni
