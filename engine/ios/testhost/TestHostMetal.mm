// iOS Phase 1 / Task 1.1 test: MetalSurfaceIOS draws a rounded rect.
// A plain CADisplayLink on main (not DisplayLinkIOS, so this gate isolates the
// surface) hands each frame to a serial "raster" queue, which runs the
// surface's raster-thread half: SetDrawableSize -> Draw -> (frame 30)
// ReadPixels -> Present. Frame 30's readback goes to Documents/metal-readback.ppm.
#import "TestHost.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <vector>

#include "host/MetalSurfaceIOS.h"
#include "host/Pixel.h"

@interface MetalTestController : UIViewController
@end

@implementation MetalTestController {
  rni::MetalSurfaceIOS _surface;
  ImpellerContext _ctx;
  dispatch_queue_t _raster;
  CADisplayLink* _link;
  std::atomic<int> _frames;
  std::atomic<bool> _busy;
  int _w, _h;
}

- (void)loadView {
  self.view = [[RNIMetalLayerView alloc] initWithFrame:UIScreen.mainScreen.bounds];
}

- (BOOL)prefersStatusBarHidden {
  return YES;
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  if (_ctx) _surface.SyncFromView(&_w, &_h);
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (_ctx) return;
  std::string err;
  if (!_surface.Attach(self.view, &err)) {
    TestLog("metal attach_failed error=%s", err.c_str());
    return;
  }
  _surface.SyncFromView(&_w, &_h);
  _raster = dispatch_queue_create("rni.testhost.raster", DISPATCH_QUEUE_SERIAL);
  dispatch_sync(_raster, ^{
    self->_ctx = self->_surface.CreateContext();
  });
  TestLog("metal context=%s drawable=%dx%d", _ctx ? "created" : "NULL", _w, _h);
  if (!_ctx) return;
  _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
  [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)tick:(CADisplayLink*)link {
  if (_busy.exchange(true)) return;  // one frame in flight, like a raster thread
  const int w = _w, h = _h;
  dispatch_async(_raster, ^{
    [self rasterFrameWidth:w height:h];
    self->_busy.store(false);
  });
}

// Raster queue.
- (void)rasterFrameWidth:(int)w height:(int)h {
  _surface.SetDrawableSize(w, h);
  const int rx = (int)std::lround(w * 0.2), ry = (int)std::lround(h * 0.3);
  const int rw = (int)std::lround(w * 0.6), rh = (int)std::lround(h * 0.25);
  const int r = (int)std::lround(std::min(rw, rh) * 0.25);

  ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
  ImpellerPaint paint = ImpellerPaintNew();
  const ImpellerColor white = {1, 1, 1, 1, kImpellerColorSpaceSRGB};
  const ImpellerColor ink = {32 / 255.f, 32 / 255.f, 32 / 255.f, 1, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &white);
  ImpellerDisplayListBuilderDrawPaint(b, paint);
  ImpellerPaintSetColor(paint, &ink);
  const ImpellerRect rect = {(float)rx, (float)ry, (float)rw, (float)rh};
  const ImpellerPoint rad = {(float)r, (float)r};
  const ImpellerRoundingRadii radii = {rad, rad, rad, rad};
  ImpellerDisplayListBuilderDrawRoundedRect(b, &rect, &radii, paint);
  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);

  const int frame = ++_frames;
  const bool drew = _surface.Draw(_ctx, dl);
  if (frame == 30) {
    std::vector<rni::Px> px;
    int pw = 0, ph = 0;
    const bool read = drew && _surface.ReadPixels(&px, &pw, &ph);
    NSString* path = [TestDocumentsDir() stringByAppendingPathComponent:@"metal-readback.ppm"];
    const bool wrote = read && rni::WritePpm(path.UTF8String, px, pw, ph);
    TestLog("readback ok=%d w=%d h=%d rrect=%d,%d,%d,%d r=%d file=metal-readback.ppm", wrote, pw,
            ph, rx, ry, rw, rh, r);
  }
  if (drew) _surface.Present();
  if (frame == 60 || frame == 240) {
    TestLog("metal frames=%d presents=%d display_sync=%d", frame, _surface.presents(),
            _surface.displaySync());
  }
  ImpellerDisplayListRelease(dl);
  ImpellerPaintRelease(paint);
  ImpellerDisplayListBuilderRelease(b);
}
@end

UIViewController* MakeMetalTest() { return [MetalTestController new]; }
