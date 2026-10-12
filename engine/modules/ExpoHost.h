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
//   ExponentConstants  optional (one console.warn when absent).
//   ExpoUpdates, ExpoGo, NativeModulesProxy
//                      optional, and must STAY absent: a present ExpoGo makes
//                      isRunningInExpoGo() true and re-routes asset loading.
// So ExpoAsset is the only module this host has to vend for boot.
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
};

// Directories the host hands Expo. Resolved once at host construction (same
// rule as AppStorageConfig: a module must not relocate its own sandbox).
struct ExpoHostConfig {
  std::filesystem::path cacheDir;
  std::filesystem::path documentsDir;
  std::shared_ptr<std::function<void(const std::string&)>> reload;
  std::shared_ptr<NetworkActivity> network;
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

// Registers the modules the engine vends to Expo (today: ExpoAsset).
void registerBuiltinExpoModules(ExpoModuleRegistry& registry,
                                std::shared_ptr<ExpoHostConfig> config);

// Installs globalThis.expo. Call from the runtime's bindings install, after
// the TurboModule binding, before the bundle is evaluated.
void installExpoGlobal(facebook::jsi::Runtime& runtime,
                       std::shared_ptr<ExpoModuleRegistry> registry,
                       std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                       std::shared_ptr<ExpoHostConfig> config);

}  // namespace rni
