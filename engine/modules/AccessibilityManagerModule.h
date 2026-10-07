// ENG-14: AccessibilityManager TurboModule (RN's iOS module name).
//
// THE BUG. AccessibilityInfo.isReduceMotionEnabled() rejected on impeller:
// its non-Android arm calls NativeAccessibilityManagerIOS, which is
// TurboModuleRegistry.get('AccessibilityManager'), and no such module was
// registered (--list-modules named none), so it hit `reject(null)`. HostApp's
// BOOT-1 then had to read a rejection as "motion is fine".
//
// THE MODULE. Every getCurrent*State(onSuccess, onError) answers from the
// host's real accessibility settings (AccessibilitySettings.h): on darwin
// NSWorkspace's accessibilityDisplayShouldReduceMotion / ...Transparency /
// ...InvertColors / ...IncreaseContrast and VoiceOver; elsewhere false. The
// states with no desktop equivalent (bold text, grayscale, cross-fade) answer
// false rather than leaving the method missing: once this module exists,
// AccessibilityInfo calls each of them directly, and a missing method would
// THROW where the absent module used to reject.
//
// RNI_REDUCE_MOTION=1|0 overrides the reduce-motion answer on every host, so
// a gate can prove both values without touching the user's system setting.
//
// Not built: the change EVENT (reduceMotionChanged on a live toggle). A
// reader gets the value current at the time it asks.
#pragma once

#include <FBReactNativeSpecJSI.h>
#include <jsi/jsi.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>

#include "modules/AccessibilitySettings.h"

namespace rni {

namespace jsi = facebook::jsi;

class AccessibilityManagerModule
    : public facebook::react::NativeAccessibilityManagerCxxSpec<
          AccessibilityManagerModule> {
 public:
  explicit AccessibilityManagerModule(
      std::shared_ptr<facebook::react::CallInvoker> jsInvoker)
      : NativeAccessibilityManagerCxxSpec(std::move(jsInvoker)) {}

  // The reduce-motion answer: RNI_REDUCE_MOTION when set, else the system.
  static bool reduceMotion() {
    if (const char* o = std::getenv("RNI_REDUCE_MOTION")) {
      if (std::strcmp(o, "1") == 0 || std::strcmp(o, "true") == 0) return true;
      if (std::strcmp(o, "0") == 0 || std::strcmp(o, "false") == 0) return false;
    }
    return ReadAccessibilitySettings().reduceMotion;
  }

  void getCurrentReduceMotionState(jsi::Runtime& rt, jsi::Function onSuccess,
                                   jsi::Function /*onError*/) {
    const bool v = reduceMotion();
    std::printf("rn-impeller: a11y reduce_motion=%d\n", (int)v);
    std::fflush(stdout);
    onSuccess.call(rt, v);
  }
  void getCurrentReduceTransparencyState(jsi::Runtime& rt,
                                         jsi::Function onSuccess,
                                         jsi::Function /*onError*/) {
    onSuccess.call(rt, ReadAccessibilitySettings().reduceTransparency);
  }
  void getCurrentInvertColorsState(jsi::Runtime& rt, jsi::Function onSuccess,
                                   jsi::Function /*onError*/) {
    onSuccess.call(rt, ReadAccessibilitySettings().invertColors);
  }
  void getCurrentDarkerSystemColorsState(jsi::Runtime& rt,
                                         jsi::Function onSuccess,
                                         jsi::Function /*onError*/) {
    onSuccess.call(rt, ReadAccessibilitySettings().increaseContrast);
  }
  void getCurrentVoiceOverState(jsi::Runtime& rt, jsi::Function onSuccess,
                                jsi::Function /*onError*/) {
    onSuccess.call(rt, ReadAccessibilitySettings().voiceOver);
  }
  // No desktop equivalent: answered, never left missing (see the header).
  void getCurrentBoldTextState(jsi::Runtime& rt, jsi::Function onSuccess,
                               jsi::Function /*onError*/) {
    onSuccess.call(rt, false);
  }
  void getCurrentGrayscaleState(jsi::Runtime& rt, jsi::Function onSuccess,
                                jsi::Function /*onError*/) {
    onSuccess.call(rt, false);
  }
  void getCurrentPrefersCrossFadeTransitionsState(jsi::Runtime& rt,
                                                  jsi::Function onSuccess,
                                                  jsi::Function /*onError*/) {
    onSuccess.call(rt, false);
  }
  // Screen-reader output is not built; these are honest no-ops.
  void setAccessibilityContentSizeMultipliers(jsi::Runtime&, jsi::Object) {}
  void setAccessibilityFocus(jsi::Runtime&, double) {}
  void announceForAccessibility(jsi::Runtime&, jsi::String) {}
  void announceForAccessibilityWithOptions(jsi::Runtime&, jsi::String,
                                           jsi::Object) {}
};

}  // namespace rni
