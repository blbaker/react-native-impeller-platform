// ModuleRegistry — THE TURBOMODULE SEAM (PLAN D7).
//
// P2 wired six TurboModules into ReactHost as an `if (name == "...")` chain in
// the middle of the constructor. That works and is untestable: the set of
// modules the engine vends is not a value anywhere, so nothing can enumerate
// it, diff it against the shipped JS, or prove a module is reachable. Every
// guard you would want to write needs the registry to be DATA.
//
// So the seam is a name -> factory table with three properties the chain did
// not have:
//
//   1. ENUMERABLE. `names()` lists what this engine vends, and `--list-modules`
//      prints it with each module's method map. That output is what the P4
//      packaging gate diffs against the shipped JS shims — the "method in
//      shim" guard from the three-layer packaging rule. A file being in the
//      tarball says nothing about whether a native method is reachable from
//      JS; only a methodMap diff does.
//
//   2. EXTENSIBLE AT ONE POINT. `add()` is the whole registration API. A
//      consumer-authored native module is v2 DX, but the seam it will plug
//      into is this, and it exists now so the shape is proven rather than
//      promised.
//
//   3. DELEGATING, NOT DUPLICATING. Unknown names fall through to RN's own
//      `DefaultTurboModules`, which is portable C++ shipping in the RN package
//      (Microtasks, DOM, FeatureFlags, IdleCallbacks, Performance...). P2
//      hand-rolled three of those by name. Hand-rolling what upstream already
//      vends means an RN bump silently leaves you on a stale set — and it is
//      how we were missing NativePerformance and NativeIdleCallbacks entirely.
//
// ⚠️ CACHING IS PART OF THE CONTRACT, NOT AN OPTIMISATION. A TurboModule that
// holds listener state (Appearance, AppState, DevSettings) must be the SAME
// object every time JS asks for it; construct a fresh one per lookup and
// `addListener` writes into an instance nothing will ever emit from. That
// failure is silent and looks like "events do not fire".
#pragma once

#include <ReactCommon/CallInvoker.h>
#include <ReactCommon/TurboModule.h>

#include <algorithm>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace rni {

namespace react = facebook::react;

class ModuleRegistry {
 public:
  using Factory = std::function<std::shared_ptr<react::TurboModule>(
      std::shared_ptr<react::CallInvoker>)>;

  // Registration order is not significant; lookup is by name.
  void add(std::string name, Factory factory) {
    factories_.emplace(std::move(name), std::move(factory));
  }

  // Names THIS registry vends, sorted. Deliberately does NOT include the
  // DefaultTurboModules fallthrough: those are upstream's to enumerate, and
  // claiming them here would make the packaging gate assert against modules
  // whose JS ships with react-native rather than with us.
  std::vector<std::string> names() const {
    std::vector<std::string> out;
    out.reserve(factories_.size());
    for (const auto& [name, _] : factories_) out.push_back(name);
    std::sort(out.begin(), out.end());
    return out;
  }

  bool has(const std::string& name) const {
    return factories_.find(name) != factories_.end();
  }

  // Returns the cached instance if there is one, else constructs and caches.
  // Returns nullptr for a name this registry does not vend — the caller is
  // expected to fall through to DefaultTurboModules and then to nullptr, which
  // is how RN's TurboModuleRegistry.get() reports "no such module" to JS.
  std::shared_ptr<react::TurboModule> get(
      const std::string& name,
      const std::shared_ptr<react::CallInvoker>& jsInvoker) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (auto it = cache_.find(name); it != cache_.end()) return it->second;
    auto it = factories_.find(name);
    if (it == factories_.end()) return nullptr;
    auto module = it->second(jsInvoker);
    if (module) cache_[name] = module;
    return module;
  }

  // ⛔ RELEASE THE CACHED MODULES WHILE THE RUNTIME IS STILL ALIVE.
  // A TurboModule holds jsi::WeakObject members (RN's TurboModule.h keeps a
  // unique_ptr<WeakObject> for its JS-side representation). ~WeakObject calls
  // into the jsi::Runtime that created it, so destroying a cached module AFTER
  // the runtime is gone dereferences a dead runtime:
  //
  //   EXC_BAD_ACCESS at 0x0
  //     facebook::jsi::Pointer::~Pointer()            jsi.h:833
  //     facebook::jsi::WeakObject::~WeakObject()      jsi.h:1461
  //     facebook::react::TurboModule::~TurboModule()  TurboModule.h:46
  //     rni::ModuleRegistry::~ModuleRegistry()        ModuleRegistry.h:53
  //
  // ~ReactHost calls this on the JS thread before dropping the instance.
  // Nothing may look a module up afterwards; the runtime is being torn down.
  void clearInstances() {
    std::lock_guard<std::mutex> lock(mutex_);
    cache_.clear();
  }

 private:
  std::unordered_map<std::string, Factory> factories_;
  std::unordered_map<std::string, std::shared_ptr<react::TurboModule>> cache_;
  std::mutex mutex_;
};

}  // namespace rni
