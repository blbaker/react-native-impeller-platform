// iOS Phase 1 / Task 1.4 test: accessibility settings and the OS appearance.
// - Appearance: the production OsAppearanceWatcher (OsAppearance.cpp + the iOS
//   hooks in OsAppearanceIOS.mm) runs against the real OS and logs every change.
// - Accessibility: a background thread (the JS thread's position) calls the
//   production ReadAccessibilitySettings() every 200 ms and logs each change.
// - UIKit's own change notifications are logged too, as evidence that a toggle
//   reached the app at all (a gate failure then says which half is wrong).
#import "TestHost.h"

#include <atomic>
#include <chrono>
#include <memory>
#include <thread>

#include "host/OsAppearance.h"
#include "modules/AccessibilitySettings.h"

namespace {
std::string Describe(const rni::AccessibilitySettings& s) {
  char buf[160];
  std::snprintf(buf, sizeof buf,
                "reduce_motion=%d reduce_transparency=%d invert=%d increase_contrast=%d voiceover=%d",
                s.reduceMotion, s.reduceTransparency, s.invertColors, s.increaseContrast, s.voiceOver);
  return buf;
}
}  // namespace

@interface SettingsTestController : UIViewController
@end

@implementation SettingsTestController {
  std::unique_ptr<rni::OsAppearanceWatcher> _watcher;
  std::thread _poller;
  std::atomic<bool> _stop;
}

- (void)dealloc {
  _stop.store(true);
  if (_poller.joinable()) _poller.join();
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (_watcher) return;
  const std::string initial = rni::DarwinOsScheme();  // main thread
  TestLog("appearance_initial scheme=%s", initial.c_str());
  _watcher = std::make_unique<rni::OsAppearanceWatcher>(initial, true, [](const std::string& s) {
    TestLog("appearance_changed scheme=%s", s.c_str());
  });
  _poller = std::thread([self] {
    std::string last;
    while (!self->_stop.load()) {
      const std::string now = Describe(rni::ReadAccessibilitySettings());
      if (now != last) {
        TestLog("settings %s%s", last.empty() ? "initial " : "", now.c_str());
        last = now;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
  });
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  for (NSString* name in @[
         UIAccessibilityReduceMotionStatusDidChangeNotification,
         UIAccessibilityDarkerSystemColorsStatusDidChangeNotification,
         UIAccessibilityReduceTransparencyStatusDidChangeNotification,
         UIAccessibilityInvertColorsStatusDidChangeNotification
       ]) {
    [nc addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification* n) {
      TestLog("a11y_notification name=%s", n.name.UTF8String);
    }];
  }
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  TestLog("settings_ready");
}

- (void)traitCollectionDidChange:(UITraitCollection*)previous {
  [super traitCollectionDidChange:previous];
  TestLog("trait_change style=%ld", (long)self.traitCollection.userInterfaceStyle);
}
@end

UIViewController* MakeSettingsTest() { return [SettingsTestController new]; }
