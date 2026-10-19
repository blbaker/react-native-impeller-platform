// iOS host phase (Task 3.2) test: RNIEngine renders a bundle.
// Compiled only into the engine build of the test host (tools/lib/ios-sim.sh
// ios_build_testhost engine), which links librni_ios_all.a and embeds
// hermesvm.framework. --bundle=<resource name> (default ios-smoke.jsbundle,
// copied into the app) and --app=<registered name> (default IosSmoke).
// --detach-after=<frames>: detach then re-attach once, to exercise the
// attach/detach lifecycle (logs engine_reattached).
#import "TestHost.h"

#include <cstdlib>
#include <string>

#import "host/MetalSurfaceIOS.h"
#import "ios/RNIEngine.h"

@interface EngineTestController : UIViewController
@end

@implementation EngineTestController {
  RNIEngine* _engine;
  CADisplayLink* _watch;
  NSUInteger _lastLogged;
  int _detachAfter;
  BOOL _reattached;
}

- (void)loadView {
  self.view = [[RNIMetalLayerView alloc] initWithFrame:UIScreen.mainScreen.bounds];
}

- (BOOL)prefersStatusBarHidden {
  return YES;
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (_engine) return;
  std::string bundle = TestArg("bundle");
  std::string app = TestArg("app");
  if (bundle.empty()) bundle = "ios-smoke.jsbundle";
  if (app.empty()) app = "IosSmoke";
  _detachAfter = std::atoi(TestArg("detach-after").c_str());
  NSString* path = [NSBundle.mainBundle.resourcePath
      stringByAppendingPathComponent:[NSString stringWithUTF8String:bundle.c_str()]];
  TestLog("engine bundle=%s app=%s", path.UTF8String, app.c_str());
  // UIKit's own view of the screen, independent of what the engine reports:
  // the gate probes the fixture's point coordinates with this scale.
  TestLog("engine uikit_points=%.0fx%.0f uikit_scale=%.2f", self.view.bounds.size.width,
          self.view.bounds.size.height, self.view.window.screen.nativeScale);
  _engine = [[RNIEngine alloc] initWithBundlePath:path appName:[NSString stringWithUTF8String:app.c_str()]];
  if (!_engine) {
    TestLog("engine init_failed");
    return;
  }
  _engine.onFirstFrame = ^{
    TestLog("engine idle first_frame=1");
  };
  // --attach-delay-ms=N holds the first attach (a slow engine start), so a gate
  // that screenshots without waiting for the first frame always catches the
  // blank screen (tools/mutation-verify-ios-sim.sh M2), instead of only when
  // it happens to win the race.
  const int delayMs = std::atoi(TestArg("attach-delay-ms").c_str());
  if (delayMs > 0) {
    TestLog("engine attach_delay_ms=%d", delayMs);
    __weak EngineTestController* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayMs * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     [weakSelf attachFirst];
                   });
  } else {
    [self attachFirst];
  }
}

- (void)attachFirst {
  const BOOL attached = [_engine attachToView:self.view];
  TestLog("engine attached=%d", attached);
  _watch = [CADisplayLink displayLinkWithTarget:self selector:@selector(watch:)];
  [_watch addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)watch:(CADisplayLink*)link {
  const NSUInteger n = _engine.presentedFrames;
  if (n >= _lastLogged + 60) {
    _lastLogged = n;
    TestLog("engine presented=%lu", (unsigned long)n);
  }
  if (_detachAfter > 0 && !_reattached && n >= (NSUInteger)_detachAfter) {
    _reattached = YES;
    [_engine detach];
    const NSUInteger frozen = _engine.presentedFrames;
    const BOOL again = [_engine attachToView:self.view];
    TestLog("engine_reattached=%d presented_at_detach=%lu", again, (unsigned long)frozen);
  }
}
@end

static UIViewController* MakeEngineTest() { return [EngineTestController new]; }
[[maybe_unused]] static const bool gRegistered = RegisterTest("engine", MakeEngineTest);
