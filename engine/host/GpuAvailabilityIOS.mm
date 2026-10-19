// iOS Phase 1 / Task 1.3: see GpuAvailabilityIOS.h. Built with -fobjc-arc.
#include "host/GpuAvailabilityIOS.h"

#import <UIKit/UIKit.h>

#include "base/GpuAvailability.h"

static_assert(__has_feature(objc_arc), "GpuAvailabilityIOS.mm must be built with -fobjc-arc");

namespace rni::gpu {
namespace {
id gBackgroundObserver = nil;  // main thread only
id gForegroundObserver = nil;
}  // namespace

void InstallGpuAvailabilityObservers() {
  if (gBackgroundObserver) return;
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  // queue:nil runs the block synchronously on the posting (main) thread, so
  // the switch is off before the notification returns to UIKit.
  gBackgroundObserver = [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                                            object:nil
                                             queue:nil
                                        usingBlock:^(NSNotification*) {
                                          Set(false, "ios_background");
                                        }];
  gForegroundObserver = [center addObserverForName:UIApplicationWillEnterForegroundNotification
                                            object:nil
                                             queue:nil
                                        usingBlock:^(NSNotification*) {
                                          Set(true, "ios_foreground");
                                        }];
  if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
    Set(false, "ios_background_at_install");
  }
}

void RemoveGpuAvailabilityObservers() {
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  if (gBackgroundObserver) [center removeObserver:gBackgroundObserver];
  if (gForegroundObserver) [center removeObserver:gForegroundObserver];
  gBackgroundObserver = nil;
  gForegroundObserver = nil;
}

}  // namespace rni::gpu
