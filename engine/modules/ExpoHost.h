// ExpoHost — the native half of `globalThis.expo`, so an Expo app's own entry
// point (`registerRootComponent` from 'expo') boots on this engine.
//
// WHAT EXPO EXPECTS FROM A HOST. expo-modules-core reads its core classes off
// a global at MODULE LOAD, before any app code runs:
//
//     export const EventEmitter = globalThis.expo.EventEmitter;   // EventEmitter.ts
//     export const NativeModule = globalThis.expo.NativeModule;   // NativeModule.ts
//
// On iOS/Android that global is installed by expo-modules-core's native side
// when the runtime is created (CoreModule.swift / CoreModule.kt describe it).
// With no host installing it, `import 'expo'` threw "Cannot read property
// 'EventEmitter' of undefined", nothing registered "main", and the surface
// painted nothing (Mac, 2026-10-10). The contract is typed in
// expo-modules-core/src/ts-declarations/global.ts:
//
//     modules, EventEmitter, NativeModule, SharedObject, SharedRef,
//     uuidv4, uuidv5, getViewConfig, reloadAppAsync, installOnUIRuntime,
//     expoModulesCoreVersion, cacheDir, documentsDir
//
// THE MEASURED BOOT SET (expo 57.0.27, prod + dev bundles, probe in
// fixtures/expo-host): the core classes above, then these module lookups:
//   ExpoAsset          REQUIRED. expo-asset's ExpoAsset.js calls
//                      requireNativeModule('ExpoAsset') at import, and
//                      Expo.fx imports expo-asset. Absent = boot throws.
//   ExpoFetchModule    REQUIRED once anything fetches: expo/winter replaces
//                      globalThis.fetch with expo/fetch (ExpoFetch.cpp).
//   ExponentConstants  optional (one console.warn when absent; ExpoConstants.cpp).
//   ExpoUpdates, ExpoGo, NativeModulesProxy
//                      optional, and must STAY absent: a present ExpoGo makes
//                      isRunningInExpoGo() true and re-routes asset loading.
// SC-44 re-measured (dev + release, requireNativeModule/requireOptional...):
// ExpoAsset, ExpoFetchModule, ExponentConstants, ExpoGo, ExpoUpdates.
//
// SPLIT. The four classes are plain JS (ExpoHost.cpp, kExpoCoreJs) with the
// semantics of expo-modules-core's own reference implementation
// (src/polyfill/CoreModule.ts); JS subclasses them (`class X extends
// NativeModule`) so they must be real constructors. Everything that needs
// the OS — uuids, digests, the asset cache, downloads, reload — is C++.
//
// ⛔ NO jsi VALUE CROSSES A THREAD. Async functions are dispatched with a
// numeric id; the C++ side settles with folly::dynamic through the CallInvoker,
// and JS looks the promise up by id. Nothing on a worker thread owns a
// jsi::Function, so there is no off-thread Runtime touch at teardown (the
// ClipboardModule promise hazard does not exist here by construction).
#pragma once

#include <ReactCommon/CallInvoker.h>
#include <folly/dynamic.h>
#include <jsi/jsi.h>

#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace rni {

struct NetworkActivity;

// Settles one pending async call. Thread-safe; may be called from any thread,
// exactly once. ok=false takes {code, message}.
using ExpoSettle = std::function<void(bool ok, folly::dynamic value)>;
using ExpoAsyncFn = std::function<void(folly::dynamic args, ExpoSettle settle)>;

// One Expo native module as JS sees it: constants copied onto the module
// object plus async functions returning Promises.
struct ExpoModuleDef {
  folly::dynamic constants = folly::dynamic::object();
  std::map<std::string, ExpoAsyncFn> asyncFunctions;
  // Optional ES5 function expression `(function (module, expo, host) {...})`,
  // run once when JS first touches the module (classes, sync methods).
  std::string js;
  // Optional: fills `host` (the third argument of `js`) with host functions.
  std::function<void(facebook::jsi::Runtime&, facebook::jsi::Object& host,
                     std::shared_ptr<facebook::react::CallInvoker>)>
      installHost;
};

// Directories the host hands Expo. Resolved once at host construction (same
// rule as AppStorageConfig: a module must not relocate its own sandbox).
struct ExpoHostConfig {
  std::filesystem::path cacheDir;
  std::filesystem::path documentsDir;
  std::shared_ptr<std::function<void(const std::string&)>> reload;
  std::shared_ptr<NetworkActivity> network;
  // Source URL of the app bundle (file://... or http://...), set before it is
  // evaluated; ExponentConstants derives the app manifest from it.
  std::shared_ptr<std::string> bundleUrl = std::make_shared<std::string>();
};

// The expo-module seam: name -> definition. Enumerable for --list-modules.
class ExpoModuleRegistry {
 public:
  void add(std::string name, ExpoModuleDef def) {
    defs_[std::move(name)] = std::move(def);
  }
  const std::map<std::string, ExpoModuleDef>& defs() const { return defs_; }

 private:
  std::map<std::string, ExpoModuleDef> defs_;
};

// Default directories for this OS, honouring RNI_CACHE_DIR / RNI_DOCUMENTS_DIR
// (gates point them at disposable paths).
std::shared_ptr<ExpoHostConfig> makeExpoHostConfig();

// Registers the modules the engine vends to Expo: ExpoAsset,
// ExponentConstants, ExpoFetchModule.
void registerBuiltinExpoModules(ExpoModuleRegistry& registry,
                                std::shared_ptr<ExpoHostConfig> config);
void registerExpoConstants(ExpoModuleRegistry& registry,
                           std::shared_ptr<ExpoHostConfig> config);
void registerExpoFetch(ExpoModuleRegistry& registry,
                       std::shared_ptr<ExpoHostConfig> config);
std::string expoUuidv4();

// Installs globalThis.expo. Call from the runtime's bindings install, after
// the TurboModule binding, before the bundle is evaluated.
void installExpoGlobal(facebook::jsi::Runtime& runtime,
                       std::shared_ptr<ExpoModuleRegistry> registry,
                       std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                       std::shared_ptr<ExpoHostConfig> config);

}  // namespace rni
