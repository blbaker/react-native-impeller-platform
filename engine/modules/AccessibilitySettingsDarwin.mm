// ENG-14: darwin accessibility display settings from NSWorkspace (the same
// switches as System Settings > Accessibility > Display). Read on every call,
// so a value asked for after the user flips the switch is current.
#import <AppKit/AppKit.h>

#include "modules/AccessibilitySettings.h"

namespace rni {

AccessibilitySettings ReadAccessibilitySettings() {
  AccessibilitySettings s;
  @autoreleasepool {
    NSWorkspace* ws = [NSWorkspace sharedWorkspace];
    s.reduceMotion = [ws accessibilityDisplayShouldReduceMotion];
    s.reduceTransparency = [ws accessibilityDisplayShouldReduceTransparency];
    s.invertColors = [ws accessibilityDisplayShouldInvertColors];
    s.increaseContrast = [ws accessibilityDisplayShouldIncreaseContrast];
    s.voiceOver = [ws isVoiceOverEnabled];
  }
  return s;
}

}  // namespace rni
