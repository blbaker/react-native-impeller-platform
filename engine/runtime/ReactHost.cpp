#include "runtime/ReactHost.h"

#include <ReactCommon/TurboModuleBinding.h>
#include <cxxreact/JSBigString.h>
#include <jserrorhandler/JsErrorHandler.h>
#include <react/nativemodule/defaults/DefaultTurboModules.h>
#include <react/renderer/runtimescheduler/RuntimeSchedulerCallInvoker.h>
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
  initialUrl_ = std::make_shared<std::string>();

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
  // Let in-flight timers/executor tasks finish (bounded) so async JS work
  // completes before the runtime goes away.
  if (jsThread_) {
    waitForJsIdle(5000);
  }
  instance_.reset();
  if (jsThread_) {
    jsThread_->quitSynchronous();
  }
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
