// ENG-14: non-darwin hosts. No system accessibility read is wired here (GNOME
// enable-animations / Windows SPI_GETCLIENTAREAANIMATION would go here), so
// every setting answers false. RNI_REDUCE_MOTION overrides reduce motion in
// AccessibilityManagerModule on every host.
#include "modules/AccessibilitySettings.h"

// darwin windowed builds compile AccessibilitySettingsDarwin.mm instead.
#if !defined(__APPLE__) || !RNI_WITH_WINDOW
namespace rni {
AccessibilitySettings ReadAccessibilitySettings() { return {}; }
}  // namespace rni
#endif
