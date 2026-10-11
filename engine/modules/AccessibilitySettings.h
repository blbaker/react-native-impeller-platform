// ENG-14: the host's accessibility display settings, read fresh on each call.
// darwin: AccessibilitySettingsDarwin.mm (NSWorkspace). Elsewhere:
// AccessibilitySettings.cpp answers all-false (no system read is wired).
#pragma once

namespace rni {

struct AccessibilitySettings {
  bool reduceMotion = false;
  bool reduceTransparency = false;
  bool invertColors = false;
  bool increaseContrast = false;
  bool voiceOver = false;
};

AccessibilitySettings ReadAccessibilitySettings();

}  // namespace rni
