#include "runtime/ReactHost.h"

#include <ReactCommon/TurboModuleBinding.h>
#include <cxxreact/JSBigString.h>
#include <jserrorhandler/JsErrorHandler.h>
#include <react/nativemodule/dom/NativeDOM.h>
#include <react/nativemodule/featureflags/NativeReactNativeFeatureFlags.h>
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
  auto moduleCache = std::make_shared<
      std::unordered_map<std::string, std::shared_ptr<react::TurboModule>>>();

  auto moduleProvider = [jsInvoker, moduleCache, scriptURL = scriptURL_,
                         metrics = displayMetrics_](
                            jsi::Runtime&, const std::string& name)
      -> std::shared_ptr<react::TurboModule> {
    if (auto it = moduleCache->find(name); it != moduleCache->end()) {
      return it->second;
    }
    std::shared_ptr<react::TurboModule> module;
    if (name == "PlatformConstants") {
      module = std::make_shared<PlatformConstantsModule>(jsInvoker);
    } else if (name == "SourceCode") {
      module = std::make_shared<SourceCodeModule>(jsInvoker, scriptURL);
    } else if (name == "ExceptionsManager") {
      module = std::make_shared<ExceptionsManagerModule>(jsInvoker);
    } else if (name == "NativeMicrotasksCxx") {
      module = std::make_shared<MicrotasksModule>(jsInvoker);
    } else if (name == "AppState") {
      module = std::make_shared<AppStateModule>(jsInvoker);
    } else if (name == "DeviceInfo") {
      module = std::make_shared<DeviceInfoModule>(jsInvoker, metrics);
    } else if (name == "NativeDOMCxx") {
      // Fabric's createPublicRootInstance calls NativeDOM.linkRootNode
      // unconditionally; without this JS gets null and the root never links.
      module = std::make_shared<react::NativeDOM>(jsInvoker);
    } else if (name == "NativeReactNativeFeatureFlagsCxx") {
      // JS reads feature flags through this module. Absent, every accessor
      // warns and returns a common default — including flags that gate
      // renderer behaviour, so JS and C++ would disagree about the same flag.
      module = std::make_shared<react::NativeReactNativeFeatureFlags>(jsInvoker);
    }
    if (module) (*moduleCache)[name] = module;
    return module;
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
