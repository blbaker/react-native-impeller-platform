// ReactHost — owns the bridgeless ReactInstance: Hermes runtime, JS thread,
// timers, TurboModule provider, bundle load.
//
// It does NOT own Fabric or rendering. FabricHost consumes the RuntimeScheduler
// and RuntimeExecutor this exposes, so the "can JS run" and "can pixels appear"
// questions stay separately answerable.
#pragma once

#include <react/renderer/runtimescheduler/RuntimeScheduler.h>
#include <react/runtime/ReactInstance.h>

#include <cstdint>
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
#include "modules/TextureRegistryModule.h"
#include "modules/ViewShotModule.h"
#include "modules/WorldRasterStore.h"
#include "scenegraph/TextureRegistry.h"
#include "modules/ClipboardBridge.h"
#include "modules/ExpoHost.h"
#include "runtime/DeviceEventSink.h"
#include "runtime/JsThread.h"
#include "runtime/NativeAnimatedPump.h"

#include <react/renderer/animated/NativeAnimatedNodesManagerProvider.h>

namespace rni {

class InspectorHost;

class ReactHost {
 public:
  // parity item 24. withInspector: register a debuggable page (HostTarget)
  // so React Native DevTools can attach through Metro. Only for bundles
  // served by Metro; release / file:// runs pay nothing.
  explicit ReactHost(bool withInspector = false);
  ~ReactHost();
  // parity item 24. Opens the inspector device socket to the Metro that
  // served sourceUrl. No-op without an inspector or for non-http URLs.
  void connectInspector(const std::string& sourceUrl, const std::string& appName);

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
  // FP-42. External textures; SceneGraph paints from the SAME registry.
  std::shared_ptr<rni::TextureRegistry> textureRegistry() { return textureRegistry_; }
  // FP-43. RNViewShot requests; SceneGraph records them from the SAME controller.
  std::shared_ptr<rni::SnapshotController> snapshots() { return snapshots_; }
  // Network activity, so a headless run can wait for in-flight REQUESTS and
  // not only for an idle JS thread. See NetworkActivity in NetworkingModule.h.
  std::shared_ptr<NetworkActivity> network() { return network_; }
  // item 5. The thread-safe clipboard bridge: the "Clipboard" TurboModule
  // posts through it, and main.cpp wires its system backend to the real
  // GLFW clipboard once a window exists. See ClipboardBridge.h.
  std::shared_ptr<ClipboardBridge> clipboard() { return clipboard_; }
  // The modules globalThis.expo.modules vends (ExpoHost.h), for --list-modules.
  std::shared_ptr<ExpoModuleRegistry> expoModules() { return expoModules_; }

  std::string jsThreadStats() const {
    return jsThread_ ? jsThread_->debugStats() : std::string();
  }

  // Blocks until the JS thread has no queued task and no live timer, or the
  // deadline passes. Returns true if it actually went idle. Used by the
  // headless gate so a frame is captured after JS work, not during it.
  bool waitForJsIdle(int timeoutMs);

  // ⛔ THE WINDOWED BOOT WAIT. TIMERS DO NOT COUNT.
  // Blocks until every task queued on the JS thread has run (including tasks
  // those tasks queue: render -> commit -> effects), but NOT until pending
  // timers fire. waitForJsIdle counts a one-shot timer as work, and RN core's
  // requestAnimationFrame IS a setTimeout(0) (TimerManager.cpp), so an app
  // running a rAF launch animation is never idle until the animation stops.
  // Using waitForJsIdle at windowed boot held the frame loop off for the
  // whole launch animation: the first present was the Home screen ~1.5 s
  // after JS started (Mac, HostApp v5, 2026-10-03; D-156). The barrier runs at
  // RuntimeScheduler IdlePriority so it lands behind React's own render and
  // effect tasks (see the .cpp; an Immediate barrier overtook them and the
  // first frame was black). Returns false on timeout.
  bool waitForJsQueueDrained(int timeoutMs);

  // Registers the names of components the engine can actually mount, so RN's
  // NativeComponentRegistry answers truthfully. Must agree with FabricHost's
  // provider registry: a component present in one and absent from the other
  // fails in a way that looks exactly like "the engine does not have it".
  void setKnownComponents(std::vector<std::string> names);

  // ENG-06. One NativeAnimated tick, driven by the host's frame loop so the
  // clock IS the frame counter and `--frames N` is deterministic. Safe and
  // near-free to call every frame: a relaxed atomic load when nothing is
  // animating. Runs RN's onRender on the CALLING thread (FP-10): call it from
  // the frame loop, never from the JS thread.
  void pumpNativeAnimated();

  // How many times RN's animation engine actually ran, for gates. See
  // NativeAnimatedPump.h for why a pixel diff alone cannot prove ENG-06.
  unsigned long nativeAnimatedTicks() const;
  // FP-11: true while an animation is in flight (one atomic load), and a hook
  // run whenever one starts (any thread) so a sleeping loop requests a frame.
  bool nativeAnimatedActive() const;
  void setNativeAnimatedStartHook(std::function<void()> hook);

  // Per-frame JS-work instruments for the native-driven-loop cost check.
  // jsTimersFired: JS timer callbacks run (setTimeout/setInterval and
  // requestAnimationFrame, which IS a setTimeout(0) here). A JS-driven
  // Animated loop fires one per frame; a native-driven one fires none.
  // nativeAnimatedTickMicros: wall time spent inside RN's C++ onRender (the
  // node-graph walk + prop apply), summed over every tick. That walk runs on
  // the frame-loop thread (see pumpNativeAnimated) and executes no JS.
  unsigned long jsTimersFired() const {
    return jsTimersFired_->load(std::memory_order_relaxed);
  }
  unsigned long long nativeAnimatedTickMicros() const;

  // ENG-06. Replace RN's animation clock with a FRAME COUNTER, and step it.
  //
  // Ticking the pump alone is not enough: RN's drivers interpolate on elapsed
  // milliseconds read from a global `g_now`, so on a ~1000fps headless loop all
  // 60 frames sample the curve at t≈0 and the animation is frozen while the
  // tick count looks perfect. Install this before the frame loop; the pump
  // advances it. See ReactHost.cpp for the one-clock-per-process caveat.
  static void installFrameCountedAnimationClock();
  static void advanceAnimationClock();
  // Frames the animation clock has advanced (FP-10 probe reads it per present).
  static uint64_t animationClockFrames();

 private:
  std::shared_ptr<JsThread> jsThread_;
  // Shared with the JsThread timer-fire callback, so the counter stays valid
  // for whichever of the two is destroyed last.
  std::shared_ptr<std::atomic<unsigned long>> jsTimersFired_ =
      std::make_shared<std::atomic<unsigned long>>(0);
  // parity item 24. Declared BEFORE instance_ so it is destroyed AFTER it:
  // the ReactInstance's inspector targets live under its HostTarget.
  std::unique_ptr<InspectorHost> inspector_;
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
  // globalThis.expo: directories + the expo-module seam. See ExpoHost.h.
  std::shared_ptr<ExpoHostConfig> expoConfig_;
  std::shared_ptr<ExpoModuleRegistry> expoModules_;
  std::shared_ptr<rni::WorldRasterStore> worldRasterStore_ =
      std::make_shared<rni::WorldRasterStore>();
  std::shared_ptr<rni::TextureRegistry> textureRegistry_ =
      std::make_shared<rni::TextureRegistry>();
  std::shared_ptr<rni::SnapshotController> snapshots_ =
      std::make_shared<rni::SnapshotController>();
  // ENG-06. The provider owns the NativeAnimatedNodesManager; the pump is the
  // clock the manager does not have. Both outlive the module, which is created
  // lazily by the registry on first JS access.
  std::shared_ptr<NativeAnimatedPump> nativeAnimatedPump_;
  std::shared_ptr<facebook::react::NativeAnimatedNodesManagerProvider>
      nativeAnimatedProvider_;
};

}  // namespace rni
