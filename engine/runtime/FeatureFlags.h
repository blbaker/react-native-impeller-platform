// Feature-flag overrides. These MUST be installed before anything reads a flag
// — ReactNativeFeatureFlags::override() throws once any accessor has run — so
// installFeatureFlags() is the first line of main(), not the ReactHost ctor.
#pragma once

#include <react/featureflags/ReactNativeFeatureFlags.h>
#include <react/featureflags/ReactNativeFeatureFlagsDefaults.h>

#include <memory>

namespace rni {

class ImpellerFeatureFlags
    : public facebook::react::ReactNativeFeatureFlagsDefaults {
 public:
  // We ARE bridgeless. HermesInstance only enables the VM microtask queue when
  // this is true; otherwise promise jobs route through a setImmediate fallback
  // that plain bundles do not have, and microtask-vs-timer ordering is wrong.
  bool enableBridgelessArchitecture() override { return true; }
  // Live Fabric — gates the renderer's transaction-mounting paths.
  bool enableFabricRenderer() override { return true; }
  // ENG-06. Selects RN's C++ NativeAnimated engine (renderer/animated/), which
  // this engine links, over the ObjC/Java TurboModule this platform does not
  // have. With this TRUE, JS's shouldUseTurboAnimatedModule() returns false and
  // NativeAnimatedHelper resolves the module name "NativeAnimatedModule" —
  // which is exactly the name ReactHost registers. Flip this to false and the
  // registration below becomes unreachable under a different name, so the two
  // are a matched pair, not two independent switches.
  bool cxxNativeAnimatedEnabled() override { return true; }
};

// Idempotent, but must run before the first flag read.
inline void installFeatureFlags() {
  static bool once = [] {
    facebook::react::ReactNativeFeatureFlags::override(
        std::make_unique<ImpellerFeatureFlags>());
    return true;
  }();
  (void)once;
}

}  // namespace rni
