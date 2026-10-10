// darwin OS appearance: NSApp effectiveAppearance (Aqua / DarkAqua).
#import <AppKit/AppKit.h>
#include <atomic>
#include <mutex>

#include "host/OsAppearance.h"

namespace rni {

namespace {
std::mutex gMutex;
std::string gCached;
}

std::string DarwinOsScheme() {
  std::string out;
  @autoreleasepool {
    NSApplication* app = [NSApplication sharedApplication];
    NSAppearanceName n = [app.effectiveAppearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    out = [n isEqualToString:NSAppearanceNameDarkAqua] ? "dark" : "light";
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
