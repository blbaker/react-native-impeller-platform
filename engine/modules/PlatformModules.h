// The D7 v1 platform module set — the modules a desktop RN app actually
// reaches for, as opposed to CoreModules.h which is only what the BOOT PATH
// requires. Every one subclasses the codegen'd CxxSpec that ships prebuilt in
// the RN package, so an upstream signature change is a compile error here
// rather than an undefined at runtime.
//
// ⛔ THE SET IS NOT WHAT THE PLAN SAID, AND THE PLAN WAS CHECKED AGAINST THE
// SOURCE RATHER THAN COPIED.
//
// PLAN D7 lists "Appearance, AppState, Alert, DevSettings stub,
// Networking(fetch), Timing". Reading RN 0.86.2:
//
//   * Timing is DEAD IN BRIDGELESS. `Libraries/Core/setUpTimers.js` only
//     touches NativeTiming in the `global.RN$Bridgeless !== true` branch;
//     bridgeless installs timers as host functions from C++ (which P2 already
//     did via TimerManager). Shipping a `Timing` module would add a module
//     nothing can ever call, and — worse — it would PASS a naive gate that
//     only checks the module resolves. Recorded here rather than silently
//     dropped.
//   * AppState is already in CoreModules.h (the boot path getEnforcing's it).
//   * StatusBarManager is ADDED, and it is the one that unblocks something
//     real: `NativeStatusBarManagerIOS.js` does `TurboModuleRegistry
//     .getEnforcing('StatusBarManager')`, so its absence THROWS at import.
//     That is precisely why the stock RN template could not run after P2.
//   * LinkingManager is ADDED because a desktop app opening a URL is a real
//     capability, and because it is the one module here with a security
//     boundary worth gating (see OpenUrl below).
//
// WHICH SPEC FLAVOUR, AND WHY IT IS NOT ARBITRARY
//
// Where RN forks a spec per platform we take the IOS flavour, matching the
// metro shim's BaseViewConfig decision — the Android variants assume
// JNI-backed managers. But the flavour choice is about the METHOD MAP only:
// every constant below describes THIS platform, not iOS.
#pragma once

#include <FBReactNativeSpecJSI.h>

#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace rni {

namespace jsi = facebook::jsi;

// ---------------------------------------------------------------------------
// Appearance — light/dark. Backed by a host-owned value so the engine can be
// told what scheme to report (--color-scheme), which is what makes the P4
// fixture able to assert that JS received it rather than a hardcoded default.
// ---------------------------------------------------------------------------

struct AppearanceState {
  std::mutex mutex;
  std::string colorScheme{"light"};

  std::string get() {
    std::lock_guard<std::mutex> lock(mutex);
    return colorScheme;
  }
  void set(std::string scheme) {
    std::lock_guard<std::mutex> lock(mutex);
    colorScheme = std::move(scheme);
  }
};

class AppearanceModule
    : public facebook::react::NativeAppearanceCxxSpec<AppearanceModule> {
 public:
  AppearanceModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                   std::shared_ptr<AppearanceState> state)
      : NativeAppearanceCxxSpec(std::move(jsInvoker)),
        state_(std::move(state)) {}

  // RN's Appearance.js treats null as "no preference" and falls back to
  // 'light'. We always have a value, so it is always returned — a null here
  // would be indistinguishable from the module being absent.
  std::optional<jsi::String> getColorScheme(jsi::Runtime& rt) {
    return jsi::String::createFromUtf8(rt, state_->get());
  }

  void setColorScheme(jsi::Runtime& rt, jsi::String scheme) {
    state_->set(scheme.utf8(rt));
  }

  void addListener(jsi::Runtime&, jsi::String) {}
  void removeListeners(jsi::Runtime&, double) {}

 private:
  std::shared_ptr<AppearanceState> state_;
};

// ---------------------------------------------------------------------------
// AlertManager. A headless engine has no dialog, and there is no honest way to
// present one — so this RECORDS the alert and invokes the callback with the
// first button, rather than doing nothing.
//
// Doing nothing would leave the JS promise in Alert.js pending forever, which
// looks like a hang rather than a missing feature. Recording it also gives the
// gate something to assert: an alert that reached native is observable.
// ---------------------------------------------------------------------------

struct AlertRecord {
  std::mutex mutex;
  std::vector<std::string> titles;

  void record(std::string title) {
    std::lock_guard<std::mutex> lock(mutex);
    titles.push_back(std::move(title));
  }
  size_t count() {
    std::lock_guard<std::mutex> lock(mutex);
    return titles.size();
  }
};

class AlertManagerModule
    : public facebook::react::NativeAlertManagerCxxSpec<AlertManagerModule> {
 public:
  AlertManagerModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                     std::shared_ptr<AlertRecord> record)
      : NativeAlertManagerCxxSpec(std::move(jsInvoker)),
        record_(std::move(record)) {}

  void alertWithArgs(jsi::Runtime& rt, jsi::Object args, jsi::Function callback);

 private:
  std::shared_ptr<AlertRecord> record_;
};

// ---------------------------------------------------------------------------
// StatusBarManager. A desktop window has no status bar, so every setter is a
// no-op and the height is 0 — but the MODULE MUST EXIST, because
// NativeStatusBarManagerIOS.js getEnforcing's it at import time and takes the
// bundle down otherwise. This is the module whose absence stopped the stock RN
// template from running after P2.
//
// A no-op here is honest (there is genuinely no status bar); compare
// LinkingManager, where a no-op would silently discard a real capability.
// ---------------------------------------------------------------------------

class StatusBarManagerModule
    : public facebook::react::NativeStatusBarManagerIOSCxxSpec<
          StatusBarManagerModule> {
 public:
  explicit StatusBarManagerModule(
      std::shared_ptr<facebook::react::CallInvoker> jsInvoker)
      : NativeStatusBarManagerIOSCxxSpec(std::move(jsInvoker)) {}

  jsi::Object getConstants(jsi::Runtime& rt) {
    jsi::Object constants(rt);
    constants.setProperty(rt, "HEIGHT", 0.0);
    constants.setProperty(rt, "DEFAULT_BACKGROUND_COLOR", 0.0);
    return constants;
  }
  void getHeight(jsi::Runtime& rt, jsi::Function callback) {
    jsi::Object result(rt);
    result.setProperty(rt, "height", 0.0);
    callback.call(rt, std::move(result));
  }
  void setNetworkActivityIndicatorVisible(jsi::Runtime&, bool) {}
  void addListener(jsi::Runtime&, jsi::String) {}
  void removeListeners(jsi::Runtime&, double) {}
  void setStyle(jsi::Runtime&, std::optional<jsi::String>, bool) {}
  void setHidden(jsi::Runtime&, bool, jsi::String) {}
};

// ---------------------------------------------------------------------------
// DevSettings. Every method is a no-op EXCEPT that the module must exist:
// NativeDevSettings.js getEnforcing's it too. Reload/hot-loading belong to a
// dev-server phase; they are stubs with a recorded consequence rather than
// pretend implementations.
// ---------------------------------------------------------------------------

class DevSettingsModule
    : public facebook::react::NativeDevSettingsCxxSpec<DevSettingsModule> {
 public:
  explicit DevSettingsModule(
      std::shared_ptr<facebook::react::CallInvoker> jsInvoker)
      : NativeDevSettingsCxxSpec(std::move(jsInvoker)) {}

  void reload(jsi::Runtime&) {}
  void reloadWithReason(jsi::Runtime&, jsi::String) {}
  void onFastRefresh(jsi::Runtime&) {}
  void setHotLoadingEnabled(jsi::Runtime&, bool) {}
  void setProfilingEnabled(jsi::Runtime&, bool) {}
  void toggleElementInspector(jsi::Runtime&) {}
  void addMenuItem(jsi::Runtime&, jsi::String) {}
  void openDebugger(jsi::Runtime&) {}
  void addListener(jsi::Runtime&, jsi::String) {}
  void removeListeners(jsi::Runtime&, double) {}
  void setIsShakeToShowDevMenuEnabled(jsi::Runtime&, bool) {}
};

// ---------------------------------------------------------------------------
// LinkingManager.
//
// ⛔ THE URL PREDICATE IS THE POINT OF THIS MODULE, AND IT LIVES IN SHARED
// CODE ON PURPOSE. On POSIX we would exec `xdg-open` with the URL as argv[1] —
// no shell, so a hostile string is at worst refused. On Windows the natural
// translation is ShellExecuteW, which RESOLVES the string the way the shell
// would: hand it a .bat, a UNC path or `file://` and it LAUNCHES it. A
// one-for-one port therefore ships a hole.
//
// So the allowlist predicate is common code, exercised by the gate on the
// platform that is actually built, protecting the platform that is not yet.
// `--test-openurl` runs it over a table of hostile inputs with no side effect.
// ---------------------------------------------------------------------------

// True only for schemes that are safe to hand to the OS opener. Rejects
// file://, UNC paths, anything with no scheme, and anything containing a
// character a shell would treat specially.
bool isOpenableUrl(const std::string& url);

// Runs isOpenableUrl over a table of hostile and benign inputs, printing one
// line per case and a verdict. No URL is ever opened. This is what lets the
// gate exercise the Windows-protecting predicate on Linux.
int runOpenUrlSelfTest();

class LinkingManagerModule
    : public facebook::react::NativeLinkingManagerCxxSpec<
          LinkingManagerModule> {
 public:
  LinkingManagerModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                       std::shared_ptr<std::string> initialUrl)
      : NativeLinkingManagerCxxSpec(std::move(jsInvoker)),
        initialUrl_(std::move(initialUrl)) {}

  // All four return a PROMISE (jsi::Value), per the codegen'd spec — the
  // static_asserts in FBReactNativeSpecJSI.h fail the build on any other
  // shape, which is exactly why we subclass the spec instead of hand-rolling.
  jsi::Value getInitialURL(jsi::Runtime& rt);
  jsi::Value canOpenURL(jsi::Runtime& rt, jsi::String url);
  jsi::Value openURL(jsi::Runtime& rt, jsi::String url);
  jsi::Value openSettings(jsi::Runtime& rt);
  void addListener(jsi::Runtime&, jsi::String) {}
  void removeListeners(jsi::Runtime&, double) {}

 private:
  std::shared_ptr<std::string> initialUrl_;
};

}  // namespace rni
