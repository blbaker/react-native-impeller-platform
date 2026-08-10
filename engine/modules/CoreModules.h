// The TurboModules the RN boot path REQUIRES before it will evaluate a real
// bundle. Every one of these is here because its absence stops the bundle at
// import time, not because it is interesting:
//
//   PlatformConstants  — Platform.js reads it at module scope
//   SourceCode         — scriptURL, used by error symbolication and HMR
//   ExceptionsManager  — where JS errors go before there is a redbox
//   NativeMicrotasksCxx— bridgeless polyfillPromise/queueMicrotask enforces it
//   AppState           — AppState.js getEnforcing's it at import time
//   DeviceInfo         — Dimensions.js reads window/screen at import time
//
// They subclass the codegen'd CxxSpecs that ship PREBUILT in the npm package
// (React/FBReactNativeSpec/FBReactNativeSpecJSI.h). We use upstream's method
// maps rather than hand-rolling jsi::HostObjects, so a signature drift in an RN
// bump is a compile error here instead of an undefined at runtime.
#pragma once

#include <FBReactNativeSpecJSI.h>
#include <react/bridging/Bridging.h>

#include <cstdio>
#include <memory>
#include <mutex>
#include <string>

namespace rni {

namespace jsi = facebook::jsi;

// Shared window metrics. The host writes on window create/resize; the JS
// thread reads. Both happen, so it is locked.
struct DisplayMetrics {
  std::mutex mutex;
  float width{800};
  float height{600};
  float scale{1};
  float fontScale{1};

  void set(float w, float h, float s) {
    std::lock_guard<std::mutex> lock(mutex);
    width = w;
    height = h;
    scale = s;
  }

  folly::dynamic toDimensionsDynamic() {
    std::lock_guard<std::mutex> lock(mutex);
    auto metrics = folly::dynamic::object("width", width)("height", height)(
        "scale", scale)("fontScale", fontScale);
    folly::dynamic m = std::move(metrics);
    return folly::dynamic::object("window", m)("screen", m);
  }
};

// ---------------------------------------------------------------------------

class PlatformConstantsModule
    : public facebook::react::NativePlatformConstantsIOSCxxSpec<
          PlatformConstantsModule> {
 public:
  explicit PlatformConstantsModule(
      std::shared_ptr<facebook::react::CallInvoker> jsInvoker)
      : NativePlatformConstantsIOSCxxSpec(std::move(jsInvoker)) {}

  // The IOS spec is used for its METHOD MAP only; the constants below describe
  // this platform. Platform.OS === 'impeller' comes from the packaged JS shim
  // (package/src/metro-shims/shims/Platform.impeller.js), not from here.
  jsi::Object getConstants(jsi::Runtime& rt) {
    jsi::Object constants(rt);
    constants.setProperty(rt, "isTesting", false);
    constants.setProperty(rt, "isDisableAnimations", false);

    jsi::Object version(rt);
    version.setProperty(rt, "major", 0);
    version.setProperty(rt, "minor", 86);
    version.setProperty(rt, "patch", 2);
    version.setProperty(rt, "prerelease", jsi::Value::null());
    constants.setProperty(rt, "reactNativeVersion", version);

    constants.setProperty(rt, "forceTouchAvailable", false);
    constants.setProperty(rt, "osVersion", jsi::String::createFromAscii(rt, "0"));
    constants.setProperty(rt, "systemName",
                          jsi::String::createFromAscii(rt, "impeller"));
    constants.setProperty(rt, "interfaceIdiom",
                          jsi::String::createFromAscii(rt, "desktop"));
    constants.setProperty(rt, "isMacCatalyst", false);
    return constants;
  }
};

class SourceCodeModule
    : public facebook::react::NativeSourceCodeCxxSpec<SourceCodeModule> {
 public:
  SourceCodeModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                   std::shared_ptr<const std::string> scriptURL)
      : NativeSourceCodeCxxSpec(std::move(jsInvoker)),
        scriptURL_(std::move(scriptURL)) {}

  jsi::Object getConstants(jsi::Runtime& rt) {
    jsi::Object constants(rt);
    constants.setProperty(
        rt, "scriptURL",
        jsi::String::createFromUtf8(rt, scriptURL_ ? *scriptURL_ : ""));
    return constants;
  }

 private:
  std::shared_ptr<const std::string> scriptURL_;
};

class ExceptionsManagerModule
    : public facebook::react::NativeExceptionsManagerCxxSpec<
          ExceptionsManagerModule> {
 public:
  explicit ExceptionsManagerModule(
      std::shared_ptr<facebook::react::CallInvoker> jsInvoker)
      : NativeExceptionsManagerCxxSpec(std::move(jsInvoker)) {}

  void reportFatalException(jsi::Runtime& rt, jsi::String message,
                            jsi::Array stack, double exceptionId) {
    report(rt, "fatal", message.utf8(rt), stack, exceptionId);
  }
  void reportSoftException(jsi::Runtime& rt, jsi::String message,
                           jsi::Array stack, double exceptionId) {
    report(rt, "soft", message.utf8(rt), stack, exceptionId);
  }
  void reportException(jsi::Runtime& rt, jsi::Object data) {
    std::string message = prop(rt, data, "message");
    bool isFatal = false;
    if (auto v = data.getProperty(rt, "isFatal"); v.isBool()) isFatal = v.getBool();
    double id = 0;
    if (auto v = data.getProperty(rt, "id"); v.isNumber()) id = v.getNumber();
    std::fprintf(stderr, "[js-exception] (%s #%d) %s\n",
                 isFatal ? "fatal" : "soft", (int)id, message.c_str());
    if (auto s = data.getProperty(rt, "stack"); s.isObject()) {
      auto o = s.getObject(rt);
      if (o.isArray(rt)) printStack(rt, o.getArray(rt));
    }
    if (auto cs = prop(rt, data, "componentStack"); !cs.empty()) {
      std::fprintf(stderr, "  component stack:\n%s\n", cs.c_str());
    }
    std::fflush(stderr);
  }
  void dismissRedbox(jsi::Runtime&) {}

 private:
  static std::string prop(jsi::Runtime& rt, const jsi::Object& obj,
                          const char* name) {
    auto v = obj.getProperty(rt, name);
    if (v.isUndefined() || v.isNull()) return "";
    return v.toString(rt).utf8(rt);
  }
  static void printStack(jsi::Runtime& rt, const jsi::Array& stack) {
    for (size_t i = 0, n = stack.size(rt); i < n; ++i) {
      auto fv = stack.getValueAtIndex(rt, i);
      if (!fv.isObject()) continue;
      auto f = fv.getObject(rt);
      auto m = prop(rt, f, "methodName");
      std::fprintf(stderr, "    at %s (%s:%s:%s)\n",
                   m.empty() ? "<anonymous>" : m.c_str(),
                   prop(rt, f, "file").c_str(), prop(rt, f, "lineNumber").c_str(),
                   prop(rt, f, "column").c_str());
    }
  }
  static void report(jsi::Runtime& rt, const char* severity,
                     const std::string& message, const jsi::Array& stack,
                     double exceptionId) {
    std::fprintf(stderr, "[js-exception] (%s #%d) %s\n", severity,
                 (int)exceptionId, message.c_str());
    printStack(rt, stack);
    std::fflush(stderr);
  }
};

class MicrotasksModule
    : public facebook::react::NativeMicrotasksCxxSpec<MicrotasksModule> {
 public:
  explicit MicrotasksModule(
      std::shared_ptr<facebook::react::CallInvoker> jsInvoker)
      : NativeMicrotasksCxxSpec(std::move(jsInvoker)) {}

  void queueMicrotask(jsi::Runtime& runtime, jsi::Function callback) {
    runtime.queueMicrotask(callback);
  }
};

class AppStateModule
    : public facebook::react::NativeAppStateCxxSpec<AppStateModule> {
 public:
  explicit AppStateModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker)
      : NativeAppStateCxxSpec(std::move(jsInvoker)) {}

  jsi::Object getConstants(jsi::Runtime& rt) {
    jsi::Object constants(rt);
    constants.setProperty(rt, "initialAppState",
                          jsi::String::createFromAscii(rt, "active"));
    return constants;
  }
  void getCurrentAppState(jsi::Runtime& rt, jsi::Function success,
                          jsi::Function /*error*/) {
    jsi::Object state(rt);
    state.setProperty(rt, "app_state", jsi::String::createFromAscii(rt, "active"));
    success.call(rt, std::move(state));
  }
  void addListener(jsi::Runtime&, jsi::String) {}
  void removeListeners(jsi::Runtime&, double) {}
};

class DeviceInfoModule
    : public facebook::react::NativeDeviceInfoCxxSpec<DeviceInfoModule> {
 public:
  DeviceInfoModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                   std::shared_ptr<DisplayMetrics> metrics)
      : NativeDeviceInfoCxxSpec(std::move(jsInvoker)),
        metrics_(std::move(metrics)) {}

  jsi::Object getConstants(jsi::Runtime& rt) {
    folly::dynamic dims =
        metrics_ ? metrics_->toDimensionsDynamic() : folly::dynamic::object();
    jsi::Object constants(rt);
    constants.setProperty(
        rt, "Dimensions",
        jsi::Value(rt, facebook::react::bridging::toJs(rt, dims, jsInvoker_)));
    constants.setProperty(rt, "isIPhoneX_deprecated", false);
    return constants;
  }

 private:
  std::shared_ptr<DisplayMetrics> metrics_;
};

}  // namespace rni
