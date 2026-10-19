// iOS Phase 1 / Task 1.4: iOS accessibility display settings from UIKit's
// UIAccessibility functions (Settings > Accessibility), the counterpart of
// AccessibilitySettingsDarwin.mm (NSWorkspace). Read on every call, so a value
// asked for after the user flips the switch is current.
// Thread: these are plain C functions over the accessibility preferences (not
// UIView/UIApplication methods), callable from the JS thread the way RN's
// AccessibilityInfo is served; the test host reads them off the main thread.
#import <UIKit/UIKit.h>

#include "modules/AccessibilitySettings.h"

namespace rni {

AccessibilitySettings ReadAccessibilitySettings() {
  AccessibilitySettings s;
  s.reduceMotion = UIAccessibilityIsReduceMotionEnabled();
  s.reduceTransparency = UIAccessibilityIsReduceTransparencyEnabled();
  s.invertColors = UIAccessibilityIsInvertColorsEnabled();
  s.increaseContrast = UIAccessibilityDarkerSystemColorsEnabled();  // "Increase Contrast"
  s.voiceOver = UIAccessibilityIsVoiceOverRunning();
  return s;
}

}  // namespace rni
