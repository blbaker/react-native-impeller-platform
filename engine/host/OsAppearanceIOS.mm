// iOS Phase 1 / Task 1.4: the OS light/dark setting on iOS, the counterpart of
// OsAppearanceDarwin.mm (NSApp effectiveAppearance). Implements the three
// darwin hooks OsAppearance.cpp calls, so its watcher thread and
// ResolveSystemScheme work unchanged. Source: the window scene's
// traitCollection.userInterfaceStyle (what RN iOS's Appearance module reports),
// falling back to the main screen's before a scene exists.
#import <UIKit/UIKit.h>

#include <mutex>

#include "host/OsAppearance.h"

namespace rni {

namespace {
std::mutex gMutex;
std::string gCached;

UITraitCollection* CurrentTraits() {
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if ([scene isKindOfClass:[UIWindowScene class]]) return ((UIWindowScene*)scene).traitCollection;
  }
  return UIScreen.mainScreen.traitCollection;
}
}  // namespace

std::string DarwinOsScheme() {
  std::string out;
  @autoreleasepool {
    out = CurrentTraits().userInterfaceStyle == UIUserInterfaceStyleDark ? "dark" : "light";
  }
  std::lock_guard<std::mutex> lock(gMutex);
  gCached = out;
  return out;
}

void DarwinRefreshOsScheme() {
  dispatch_async(dispatch_get_main_queue(), ^{ DarwinOsScheme(); });
}

std::string DarwinCachedOsScheme() {
  std::lock_guard<std::mutex> lock(gMutex);
  return gCached;
}

}  // namespace rni
