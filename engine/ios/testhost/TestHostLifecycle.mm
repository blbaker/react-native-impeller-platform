// iOS Phase 1 / Task 1.3 test: no GPU work while the app is in the background.
// A raster std::thread (like the engine's) renders every 16 ms inside a
// rni::gpu::Section: an onscreen frame through MetalSurfaceIOS (draw + present)
// plus an offscreen draw into a wrapped MTLTexture (GPU work that needs no
// drawable, the way an IO-thread upload or snapshot would). When the section
// is unavailable it only counts a skipped frame.
// The production InstallGpuAvailabilityObservers() is called at load. The
// test's OWN lifecycle observer (not the production one) keeps the process
// running in the background (beginBackgroundTask) and samples the counters at
// background+0.1 s and +1.1 s, then 1 s after the foreground.
#import "TestHost.h"

#import <Metal/Metal.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <thread>

#include "base/GpuAvailability.h"
#include "host/GpuAvailabilityIOS.h"
#include "host/MetalSurfaceIOS.h"

namespace {
struct Counts {
  std::atomic<long> presents{0}, draws{0}, offscreen{0}, skipped{0};
};

void Sample(const Counts& c, const char* tag) {
  TestLog("gpu_sample tag=%s presents=%ld draws=%ld offscreen=%ld skipped=%ld", tag,
          c.presents.load(), c.draws.load(), c.offscreen.load(), c.skipped.load());
}

ImpellerDisplayList Frame(long n, int w, int h) {
  ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
  ImpellerPaint paint = ImpellerPaintNew();
  const ImpellerColor bg = {0.1f, 0.3f, 0.6f, 1, kImpellerColorSpaceSRGB};
  const ImpellerColor box = {1, 1, 1, 1, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &bg);
  ImpellerDisplayListBuilderDrawPaint(b, paint);
  ImpellerPaintSetColor(paint, &box);
  const ImpellerRect r = {(float)((n * 6) % std::max(1, w - 60)), h / 2.0f - 30, 60, 60};
  ImpellerDisplayListBuilderDrawRect(b, &r, paint);
  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);
  ImpellerPaintRelease(paint);
  ImpellerDisplayListBuilderRelease(b);
  return dl;
}
}  // namespace

@interface GpuTestController : UIViewController
@end

@implementation GpuTestController {
  rni::MetalSurfaceIOS _surface;
  ImpellerContext _ctx;
  id<MTLTexture> _offscreen;
  std::thread _raster;
  std::atomic<bool> _stop;
  Counts _c;
  int _w, _h;
  UIBackgroundTaskIdentifier _bgTask;
}

- (void)loadView {
  self.view = [[RNIMetalLayerView alloc] initWithFrame:UIScreen.mainScreen.bounds];
}

- (void)dealloc {
  _stop.store(true);
  if (_raster.joinable()) _raster.join();
}

- (void)viewDidLoad {
  [super viewDidLoad];
  rni::gpu::InstallGpuAvailabilityObservers();
  TestLog("gpu observers_installed=1");
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  [nc addObserver:self selector:@selector(didBackground:)
             name:UIApplicationDidEnterBackgroundNotification object:nil];
  [nc addObserver:self selector:@selector(willForeground:)
             name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (_ctx) return;
  std::string err;
  if (!_surface.Attach(self.view, &err)) {
    TestLog("gpu attach_failed error=%s", err.c_str());
    return;
  }
  _surface.SyncFromView(&_w, &_h);
  _ctx = _surface.CreateContext();
  MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                               width:256
                                                                              height:256
                                                                           mipmapped:NO];
  d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  d.storageMode = MTLStorageModePrivate;
  _offscreen = [MTLCreateSystemDefaultDevice() newTextureWithDescriptor:d];
  TestLog("gpu context=%s offscreen=%d", _ctx ? "created" : "NULL", _offscreen != nil);
  if (!_ctx) return;
  _raster = std::thread([self] { [self rasterLoop]; });
}

- (void)rasterLoop {
  const int w = _w, h = _h;
  for (long n = 1; !_stop.load(); ++n) {
    {
      rni::gpu::Section section;
      if (!section.available()) {
        rni::gpu::Note(rni::gpu::Counter::kSkippedFrame);
        ++_c.skipped;
      } else {
        ImpellerDisplayList dl = Frame(n, w, h);
        if (_surface.Draw(_ctx, dl)) {
          rni::gpu::Note(rni::gpu::Counter::kDraw);
          ++_c.draws;
          _surface.Present();
          rni::gpu::Note(rni::gpu::Counter::kPresent);
          ++_c.presents;
        }
        ImpellerSurface off = ImpellerSurfaceCreateWrappedMetalTextureNew(_ctx, (__bridge void*)_offscreen);
        if (off && ImpellerSurfaceDrawDisplayList(off, dl)) ++_c.offscreen;
        ImpellerSurfaceRelease(off);
        ImpellerDisplayListRelease(dl);
      }
    }
    if (n == 60) Sample(_c, "ready");
    std::this_thread::sleep_for(std::chrono::milliseconds(16));
  }
}

- (void)didBackground:(NSNotification*)note {
  _bgTask = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
    [UIApplication.sharedApplication endBackgroundTask:self->_bgTask];
  }];
  Sample(_c, "background");
  dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  // The window opens 100 ms in (the production observer flipped the switch
  // inside this same notification) and closes 1 s later, while the loop still
  // runs often: measured in this window, 13-25 skipped frames with the switch
  // and 8-11 presents without it; from +0.5 s to +2.5 s only ~2 iterations ran,
  // which would make a zero cheap.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), q, ^{
    Sample(self->_c, "bg_start");
  });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1100 * NSEC_PER_MSEC), q, ^{
    Sample(self->_c, "bg_end");
  });
}

- (void)willForeground:(NSNotification*)note {
  Sample(_c, "foreground");
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC),
                 dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                   Sample(self->_c, "fg_after");
                 });
  if (_bgTask != UIBackgroundTaskInvalid) {
    [UIApplication.sharedApplication endBackgroundTask:_bgTask];
    _bgTask = UIBackgroundTaskInvalid;
  }
}
@end

UIViewController* MakeGpuAvailabilityTest() { return [GpuTestController new]; }
