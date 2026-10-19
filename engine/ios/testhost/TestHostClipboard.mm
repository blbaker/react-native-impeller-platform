// iOS Phase 1 / Task 1.5 test: a write through ClipboardBridge reaches the OS.
// InstallIOSClipboard() puts UIPasteboard behind a ClipboardBridge; a
// std::thread (the JS thread's position) posts the write of --clip=<value>
// through bridge.postToMain, as ClipboardModule::setString does. Then, on main:
// UIPasteboard.changeCount before/after (no content read), a direct
// UIPasteboard.general.string read (bypassing the bridge; only when the
// change count moved, so it reads this app's own content and never triggers
// iOS's paste-consent alert), and a read back through the bridge. The gate
// also reads the pasteboard from outside the app (simctl pbpaste).
#import "TestHost.h"

#include <thread>

#include "modules/ClipboardBridge.h"
#include "modules/ClipboardIOS.h"

namespace {
rni::ClipboardBridge gBridge;  // outlives the app, as InstallIOSClipboard requires
}

@interface ClipboardTestController : UIViewController
@end

@implementation ClipboardTestController {
  NSInteger _before;
  bool _started;
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (_started) return;
  _started = true;
  const std::string value = TestArg("clip");
  rni::InstallIOSClipboard(gBridge);
  _before = UIPasteboard.generalPasteboard.changeCount;
  TestLog("clipboard installed=1 change_count_before=%ld", (long)_before);
  __weak ClipboardTestController* weakSelf = self;
  std::thread([value, weakSelf] {
    gBridge.postToMain([value, weakSelf] {
      gBridge.setSystemNow(value);
      TestLog("clipboard write_done value=%s", value.c_str());
      [weakSelf afterWrite:value];
    });
  }).detach();
}

// Main thread, inside drainMain (the write task).
- (void)afterWrite:(const std::string&)value {
  const NSInteger after = UIPasteboard.generalPasteboard.changeCount;
  TestLog("clipboard change_count_after=%ld", (long)after);
  if (after != _before) {
    NSString* s = UIPasteboard.generalPasteboard.string;
    TestLog("clipboard direct_read=%s", s ? s.UTF8String : "(nil)");
  } else {
    TestLog("clipboard direct_read=skipped (change count did not move)");
    return;
  }
  std::thread([] {
    gBridge.postToMain([] { TestLog("clipboard bridge_read=%s", gBridge.getSystemNow().c_str()); });
  }).detach();
}
@end

UIViewController* MakeClipboardTest() { return [ClipboardTestController new]; }
