#include "runtime/ReactHost.h"

#include <ReactCommon/TurboModuleBinding.h>
#include <cxxreact/JSBigString.h>
#include <jserrorhandler/JsErrorHandler.h>
#include <react/nativemodule/defaults/DefaultTurboModules.h>
#include <react/renderer/runtimescheduler/RuntimeSchedulerCallInvoker.h>
#include <react/renderer/animated/AnimatedModule.h>
#include <react/renderer/animated/NativeAnimatedNodesManagerProvider.h>
#include <react/runtime/PlatformTimerRegistry.h>
#include <react/runtime/TimerManager.h>
#include <react/runtime/hermes/HermesInstance.h>

#include <chrono>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <thread>
#include <unordered_map>

#include "runtime/FeatureFlags.h"

namespace rni {

namespace react = facebook::react;

namespace {

// Timers live on the JS thread's deadline heap, so setTimeout fires on the
// thread that owns the runtime rather than being marshalled from a helper.
class TimerRegistry : public react::PlatformTimerRegistry {
 public:
  explicit TimerRegistry(std::shared_ptr<JsThread> jsThread)
      : jsThread_(std::move(jsThread)) {}

  void createTimer(uint32_t id, double delayMS) override {
    jsThread_->scheduleTimer(id, delayMS, false);
  }
  void deleteTimer(uint32_t id) override { jsThread_->cancelTimer(id); }
  void createRecurringTimer(uint32_t id, double delayMS) override {
    jsThread_->scheduleTimer(id, delayMS, true);
  }
  void quit() override { jsThread_->cancelAllTimers(); }

 private:
  std::shared_ptr<JsThread> jsThread_;
};

// ReactInstance's builtins do not install a console for a plain bundle.
void installConsole(jsi::Runtime& runtime) {
  auto log = jsi::Function::createFromHostFunction(
      runtime, jsi::PropNameID::forAscii(runtime, "log"), 1,
      [](jsi::Runtime& rt, const jsi::Value&, const jsi::Value* args,
         size_t count) -> jsi::Value {
        std::string line;
        for (size_t i = 0; i < count; ++i) {
          if (i) line += " ";
          line += args[i].toString(rt).utf8(rt);
        }
        std::printf("[js] %s\n", line.c_str());
        std::fflush(stdout);
        return jsi::Value::undefined();
      });
  jsi::Object console(runtime);
  console.setProperty(runtime, "log", log);
  console.setProperty(runtime, "info", log);
  console.setProperty(runtime, "warn", log);
  console.setProperty(runtime, "error", log);
  runtime.global().setProperty(runtime, "console", console);
}

// RN's NativeComponentRegistry asks this global whether a native component
// exists before creating a host component for it. Answering `true` for
// something the engine cannot mount produces a crash during render; answering
// `false` for something it CAN mount makes RN silently take a fallback path,
// which is indistinguishable from the engine lacking the component. So the
// answer is driven by one shared list, set from FabricHost's registration.
void installHasComponent(jsi::Runtime& runtime,
                         std::shared_ptr<std::vector<std::string>> known) {
  auto fn = jsi::Function::createFromHostFunction(
      runtime,
      jsi::PropNameID::forAscii(runtime, "__nativeComponentRegistry__hasComponent"),
      1,
      [known = std::move(known)](jsi::Runtime& rt, const jsi::Value&,
                                 const jsi::Value* args,
                                 size_t count) -> jsi::Value {
        if (count < 1 || !args[0].isString()) return jsi::Value(false);
        auto name = args[0].asString(rt).utf8(rt);
        for (const auto& k : *known) {
          if (k == name) return jsi::Value(true);
        }
        return jsi::Value(false);
      });
  runtime.global().setProperty(
      runtime, "__nativeComponentRegistry__hasComponent", fn);
}

}  // namespace

ReactHost::ReactHost() {
  installFeatureFlags();

  jsThread_ = std::make_shared<JsThread>();
  scriptURL_ = std::make_shared<std::string>();
  displayMetrics_ = std::make_shared<DisplayMetrics>();
  knownComponents_ = std::make_shared<std::vector<std::string>>();
  appearance_ = std::make_shared<AppearanceState>();
  alerts_ = std::make_shared<AlertRecord>();
  network_ = std::make_shared<NetworkActivity>();
  initialUrl_ = std::make_shared<std::string>();
  // ENG-04. Container resolved ONCE, here, from the environment -- not inside
  // the module, which must not be able to move its own sandbox.
  //
  // ⛔ THE OVERRIDE IS WHAT MAKES THIS TESTABLE, AND IT IS ALSO A RISK.
  // RNI_STORAGE_DIR lets a gate point storage at a disposable directory so a
  // two-run persistence test does not write into the developer's real home.
  // It is read once at construction; nothing after boot can change it.
  storage_ = std::make_shared<AppStorageConfig>();
  if (const char* override = std::getenv("RNI_STORAGE_DIR");
      override != nullptr && *override != '\0') {
    storage_->container = std::filesystem::path(override);
  } else {
    // Default: an app-scoped directory under the user's data location. NOT the
    // cwd -- a storage container that moves when you run the binary from a
    // different directory looks like "settings randomly reset".
    const char* home = std::getenv("HOME");
#if defined(_WIN32)
    if (home == nullptr) home = std::getenv("USERPROFILE");
#endif
    std::filesystem::path base =
        home != nullptr ? std::filesystem::path(home) : std::filesystem::path(".");
#if defined(__APPLE__)
    // The darwin app container, which is what the ledger row asked for.
    base = base / "Library" / "Application Support";
#else
    base = base / ".local" / "share";
#endif
    storage_->container = base / "rn-impeller" / "storage";
  }

  auto jsRuntime = react::HermesInstance::createJSRuntime(
      /*crashManager*/ nullptr, jsThread_, /*allocInOldGenBeforeTTI*/ false);

  auto timerManager =
      std::make_shared<react::TimerManager>(std::make_unique<TimerRegistry>(jsThread_));

  // Weak: TimerManager outlives us only through ReactInstance, and a strong
  // capture here would keep it alive past the runtime it calls into.
  jsThread_->setTimerFireCallback(
      [weak = std::weak_ptr<react::TimerManager>(timerManager)](uint32_t id) {
        if (auto tm = weak.lock()) {
          tm->callTimer(static_cast<react::TimerHandle>(id));
        }
      });

  react::JsErrorHandler::OnJsError onJsError =
      [](jsi::Runtime&, const react::JsErrorHandler::ProcessedError& error) {
        std::fprintf(stderr, "[js-error] %s\n", error.message.c_str());
        std::fflush(stderr);
      };

  instance_ = std::make_unique<react::ReactInstance>(
      std::move(jsRuntime), jsThread_, timerManager, std::move(onJsError),
      /*parentInspectorTarget*/ nullptr);

  timerManager->setRuntimeExecutor(instance_->getBufferedRuntimeExecutor());

  // ⛔ BUFFERED, matching the timer manager and NOT runtimeExecutor().
  // The unbuffered executor exists so Fabric's UIManagerBinding install is not
  // queued behind anything. A device event has the opposite requirement: an
  // emit issued before the bundle is evaluated must WAIT for the runtime
  // rather than run against a global that has no __rctDeviceEventEmitter yet.
  deviceEvents_->setRuntimeExecutor(instance_->getBufferedRuntimeExecutor());

  auto jsInvoker = std::make_shared<react::RuntimeSchedulerCallInvoker>(
      std::weak_ptr<react::RuntimeScheduler>(instance_->getRuntimeScheduler()));

  // ---------------------------------------------------------------------
  // THE SEAM (D7). What was an if-chain in P2 is now a name->factory table,
  // because the set of modules this engine vends has to be DATA for anything
  // to be able to enumerate, diff or gate it. `--list-modules` prints this
  // registry and the P4 packaging gate diffs that output against the shipped
  // JS shims — the "method in shim" guard that a file-presence check cannot
  // give you.
  //
  // Boot-path modules (CoreModules.h) and platform modules (PlatformModules.h)
  // register identically. The distinction is documentation, not mechanism: a
  // consumer-authored module in v2 will call the same add().
  // ---------------------------------------------------------------------
  modules_ = std::make_shared<ModuleRegistry>();

  // -- boot path: every one of these stops the bundle at import if absent --
  modules_->add("PlatformConstants", [](auto inv) {
    return std::make_shared<PlatformConstantsModule>(inv);
  });
  modules_->add("SourceCode", [url = scriptURL_](auto inv) {
    return std::make_shared<SourceCodeModule>(inv, url);
  });
  modules_->add("ExceptionsManager", [](auto inv) {
    return std::make_shared<ExceptionsManagerModule>(inv);
  });
  modules_->add("AppState", [](auto inv) {
    return std::make_shared<AppStateModule>(inv);
  });
  modules_->add("DeviceInfo", [m = displayMetrics_](auto inv) {
    return std::make_shared<DeviceInfoModule>(inv, m);
  });

  // -- D7 platform set --
  modules_->add("Appearance", [s = appearance_](auto inv) {
    return std::make_shared<AppearanceModule>(inv, s);
  });
  modules_->add("AlertManager", [r = alerts_](auto inv) {
    return std::make_shared<AlertManagerModule>(inv, r);
  });
  // StatusBarManager is getEnforcing'd by NativeStatusBarManagerIOS.js, so its
  // absence THREW at import — this is what stopped the stock RN template from
  // running after P2.
  modules_->add("StatusBarManager", [](auto inv) {
    return std::make_shared<StatusBarManagerModule>(inv);
  });
  modules_->add("DevSettings", [](auto inv) {
    return std::make_shared<DevSettingsModule>(inv);
  });
  modules_->add("LinkingManager", [u = initialUrl_](auto inv) {
    return std::make_shared<LinkingManagerModule>(inv, u);
  });
  // Networking — what fetch() and XMLHttpRequest reach for. Registered here
  // and NOT getEnforcing'd anywhere, which is exactly why its absence was
  // silent: RN's JS installs a real global `fetch` regardless, so the bundle
  // ran fine and every request failed. See NetworkingModule.h.
  modules_->add("Networking", [n = network_](auto inv) {
    return std::make_shared<NetworkingModule>(inv, n);
  });
  // ENG-04 shape B. ONE narrow file primitive; the AsyncStorage-shaped API is
  // a JS shim on top. See AppStorageModule.h for why the engine does not vend
  // a Storage API itself -- short version: persistence is not a renderer
  // concern, and every future syscall need would otherwise become its own
  // hand-written engine surface.
  //
  // ⚠️ NOT getEnforcing'd by anything in RN, so its absence would be SILENT --
  // the same trap Networking documents two lines up. The gate therefore asserts
  // a real round trip, not that the module resolves.
  modules_->add("AppStorage", [s = storage_](auto inv) {
    return std::make_shared<AppStorageModule>(inv, s);
  });

  // ENG-06. RN's own C++ NativeAnimated engine (ReactCommon/react/renderer/
  // animated/), already compiled by cmake/ReactCommonFabric.cmake and, until
  // now, linked into the binary and reachable by nothing.
  //
  // The name is exactly NativeAnimatedModuleCxxSpec::kModuleName. It is the
  // name JS resolves only because ImpellerFeatureFlags::cxxNativeAnimatedEnabled
  // is true; with that flag false, NativeAnimatedHelper asks for
  // "NativeAnimatedTurboModule" instead and this registration is dead code.
  //
  // ⚠️ ITS ABSENCE IS NOT SILENT, AND THAT IS WHY THIS IS A REGISTRATION AND
  // NOT A SHIM. `useNativeDriver: true` with no module THROWS an Invariant
  // Violation, after which Fabric REMOVEs and DELETEs every tag and the surface
  // paints solid background -- one black RootView, no error on screen. So the
  // failure mode looked like "the renderer painted nothing" rather than "a
  // module is missing", which is how this survived to ENG-06.
  //
  // The provider is built ONCE and captured, not created per lookup: it owns
  // the NativeAnimatedNodesManager and the manager holds every animated node.
  // A fresh provider per lookup would silently start a second, empty graph.
  nativeAnimatedPump_ = std::make_shared<NativeAnimatedPump>();
  nativeAnimatedProvider_ =
      std::make_shared<react::NativeAnimatedNodesManagerProvider>(
          [pump = nativeAnimatedPump_](std::function<void()>&& onRender,
                                       bool isAsync) {
            pump->start(std::move(onRender), isAsync);
          },
          [pump = nativeAnimatedPump_](bool isAsync) { pump->stop(isAsync); },
          /*frameRateListenerCallback*/ nullptr);
  modules_->add("NativeAnimatedModule",
                [provider = nativeAnimatedProvider_](auto inv) {
                  return std::make_shared<react::AnimatedModule>(inv, provider);
                });

  auto moduleProvider = [jsInvoker, modules = modules_](
                            jsi::Runtime&, const std::string& name)
      -> std::shared_ptr<react::TurboModule> {
    if (auto module = modules->get(name, jsInvoker)) return module;
    // ⛔ DELEGATE, DO NOT DUPLICATE. RN ships DefaultTurboModules as portable
    // C++ in the package: Microtasks, DOM, FeatureFlags, IdleCallbacks,
    // Performance and the observers. P2 hand-rolled three of those by name and
    // was therefore silently MISSING NativePerformance and NativeIdleCallbacks
    // — and a hand-rolled set goes stale on the next RN bump with no signal.
    return react::DefaultTurboModules::getTurboModule(name, jsInvoker);
  };

  // bindingsInstallFunc runs at the END of initializeRuntime, after
  // RN$Bridgeless is defined, so TurboModuleBinding::install takes the
  // bridgeless nativeModuleProxy path rather than the legacy one.
  instance_->initializeRuntime(
      {.isProfiling = false},
      [moduleProvider = std::move(moduleProvider),
       known = knownComponents_](jsi::Runtime& runtime) {
        installConsole(runtime);
        installHasComponent(runtime, known);
        react::TurboModuleBinding::install(
            runtime,
            react::TurboModuleProviderFunctionTypeWithRuntime(moduleProvider));
      });
}

ReactHost::~ReactHost() {
  // ⛔ FIRST, BEFORE ANYTHING ELSE IS TORN DOWN.
  // deviceEvents_ closes over the ReactInstance via the runtime executor. A
  // window resize arrives on the MAIN thread, not the JS thread, so a drag
  // during shutdown can call emit() while this destructor runs -- scheduling
  // work against an instance being freed underneath it. invalidate() takes the
  // sink's own mutex, so an emit already inside the lock finishes and every
  // later one takes the named-drop path instead of touching dead memory.
  if (deviceEvents_) {
    deviceEvents_->invalidate();
  }

  // Let in-flight timers/executor tasks finish (bounded) so async JS work
  // completes before the runtime goes away.
  if (jsThread_) {
    waitForJsIdle(5000);
  }

  // ⛔ TEARDOWN ORDER IS LOAD-BEARING, AND THE RUNTIME MUST OUTLIVE THE MODULES.
  //
  // A TurboModule holds jsi::WeakObject members, and ~WeakObject calls into the
  // jsi::Runtime that created it. ModuleRegistry caches every module it vends,
  // so if the registry outlives the runtime its destructor walks that cache and
  // dereferences a dead runtime. Measured, not guessed — the debug build's
  // crash report named every frame:
  //
  //   EXC_BAD_ACCESS at 0x0
  //     facebook::jsi::Pointer::~Pointer()            jsi.h:833
  //     facebook::jsi::WeakObject::~WeakObject()      jsi.h:1461
  //     facebook::react::TurboModule::~TurboModule()  TurboModule.h:46
  //     rni::ModuleRegistry::~ModuleRegistry()        ModuleRegistry.h:53
  //
  // Linux tolerated the wrong order for six phases; macOS faults on it. The
  // crash is at TEARDOWN, so `--list-modules` printed its COMPLETE, CORRECT
  // manifest and MODULE_MANIFEST_END and *then* died with rc=139 — correct
  // output, wrong exit code, which is why every gate that piped the output
  // (`| sed`, `| tail`) read the PIPE's status and called it green.
  //
  // Both steps run on the JS thread: that thread owns the runtime, and jsi
  // objects must be released on it.
  if (jsThread_) {
    jsThread_->runOnQueueSync([this] {
      if (modules_) modules_->clearInstances();
      instance_.reset();
    });
  }
  instance_.reset();  // no-op if the above ran; correct if there is no thread

  if (jsThread_) {
    jsThread_->quitSynchronous();
  }
}

// ENG-06. Called once per frame from the host's render loop, so the animation
// clock IS the frame counter: `--frames N` advances the animation the same
// number of steps on every machine. Wall-clock driving would make every
// animation gate a race.
//
// ⛔ THE EARLY-OUT IS LOAD-BEARING, NOT AN OPTIMISATION. scheduleWork() on an
// idle app would post a JS task every single frame, which keeps the JS thread
// permanently non-idle and makes waitForJsIdle() -- the thing every headless
// gate blocks on -- never return. Two acquire loads and out.
void ReactHost::pumpNativeAnimated() {
  if (!nativeAnimatedPump_ || !instance_) {
    return;
  }
  if (!nativeAnimatedPump_->isActive()) {
    return;
  }
  auto scheduler = instance_->getRuntimeScheduler();
  if (!scheduler) {
    return;
  }
  // Hop to the JS thread: tick() walks the animated node graph and touches the
  // shadow tree and JSI, which is JS-thread work in this engine.
  scheduler->scheduleWork(
      [pump = nativeAnimatedPump_](facebook::jsi::Runtime&) { pump->tick(); });
}

unsigned long ReactHost::nativeAnimatedTicks() const {
  return nativeAnimatedPump_ ? nativeAnimatedPump_->ticks() : 0UL;
}

void ReactHost::setKnownComponents(std::vector<std::string> names) {
  *knownComponents_ = std::move(names);
}

void ReactHost::runScript(std::string source, const std::string& sourceURL) {
  *scriptURL_ = sourceURL;
  instance_->loadScript(
      std::make_unique<react::JSBigStdString>(std::move(source)), sourceURL);
}

bool ReactHost::loadBundleFromFile(const std::string& bundlePath) {
  std::ifstream file(bundlePath, std::ios::binary);
  if (!file) {
    std::fprintf(stderr, "[react] cannot open bundle: %s\n", bundlePath.c_str());
    return false;
  }
  std::ostringstream ss;
  ss << file.rdbuf();
  runScript(ss.str(), "file://" + bundlePath);
  return true;
}

bool ReactHost::waitForJsIdle(int timeoutMs) {
  auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
  while (std::chrono::steady_clock::now() < deadline) {
    if (jsThread_->isIdle()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  return jsThread_->isIdle();
}

}  // namespace rni
