// iOS Phase 1 / Task 1.5: see ClipboardIOS.h. Built with -fobjc-arc.
#include "modules/ClipboardIOS.h"

#import <UIKit/UIKit.h>

#include "modules/ClipboardBridge.h"

static_assert(__has_feature(objc_arc), "ClipboardIOS.mm must be built with -fobjc-arc");

namespace rni {

void InstallIOSClipboard(ClipboardBridge& bridge) {
  bridge.setSystemBackend(
      []() -> std::string {  // main thread (drainMain or a main-thread caller)
        NSString* s = UIPasteboard.generalPasteboard.string;
        return s ? std::string(s.UTF8String) : std::string();
      },
      [](const std::string& s) {  // main thread
        UIPasteboard.generalPasteboard.string = [NSString stringWithUTF8String:s.c_str()] ?: @"";
      });
  ClipboardBridge* b = &bridge;
  bridge.setWake([b] {
    dispatch_async(dispatch_get_main_queue(), ^{
      b->drainMain();
    });
  });
}

}  // namespace rni
