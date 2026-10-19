// iOS Phase 1 / Task 1.1: see MetalSurfaceIOS.h. Built with -fobjc-arc.
#include "host/MetalSurfaceIOS.h"

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <TargetConditionals.h>

#include <atomic>
#include <cstdio>

#include "host/DisplayLinkIOS.h"

static_assert(__has_feature(objc_arc), "MetalSurfaceIOS.mm must be built with -fobjc-arc");

@implementation RNIMetalLayerView
+ (Class)layerClass {
  return [CAMetalLayer class];
}
@end

namespace rni {

struct MetalSurfaceIOS::Impl {
  __weak UIView* view = nil;
  CAMetalLayer* layer = nil;
  id<MTLDevice> device = nil;
  id<CAMetalDrawable> drawable = nil;  // acquired by Draw, dropped by Present
  ImpellerSurface surface = nullptr;
  std::atomic<int> presents{0};
  std::atomic<bool> displaySync{true};

  void DropDrawable() {
    if (surface) ImpellerSurfaceRelease(surface);
    surface = nullptr;
    drawable = nil;
  }
};

MetalSurfaceIOS::MetalSurfaceIOS() : impl_(std::make_unique<Impl>()) {}
MetalSurfaceIOS::~MetalSurfaceIOS() { Release(); }

bool MetalSurfaceIOS::Attach(UIView* view, std::string* error) {
  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };
  if (!view) return fail("metal-ios: no view");
  if (![view.layer isKindOfClass:[CAMetalLayer class]]) {
    return fail("metal-ios: the view's layer is not a CAMetalLayer (+layerClass)");
  }
  // ImpellerContextCreateMetalNew uses the system default device; the layer
  // must hand out drawables from the same one (impeller.h).
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) return fail("metal-ios: MTLCreateSystemDefaultDevice returned nil");
  CAMetalLayer* layer = (CAMetalLayer*)view.layer;
  layer.device = device;
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer.framebufferOnly = NO;  // ios_surface_metal_impeller.mm: readable surface data
  impl_->view = view;
  impl_->layer = layer;
  impl_->device = device;
  int w = 0, h = 0;
  SyncFromView(&w, &h);
  std::printf("rn-impeller: metal_layer pixel_format=%s framebuffer_only=%d contents_scale=%.2f "
              "drawable=%.0fx%.0f device=%s\n",
              layer.pixelFormat == MTLPixelFormatBGRA8Unorm ? "bgra8" : "other",
              layer.framebufferOnly ? 1 : 0, layer.contentsScale, layer.drawableSize.width,
              layer.drawableSize.height, [[device name] UTF8String]);
  std::fflush(stdout);
  return true;
}

void MetalSurfaceIOS::SyncFromView(int* w, int* h) {
  UIView* view = impl_->view;
  CAMetalLayer* layer = impl_->layer;
  if (!view || !layer) return;
  UIScreen* screen = view.window.windowScene.screen ?: UIScreen.mainScreen;
  layer.contentsScale = screen.nativeScale;
  const CGSize pts = view.bounds.size;
  const int pw = (int)(pts.width * layer.contentsScale + 0.5);
  const int ph = (int)(pts.height * layer.contentsScale + 0.5);
  if (pw > 0 && ph > 0) layer.drawableSize = CGSizeMake(pw, ph);
  if (w) *w = pw;
  if (h) *h = ph;
}

ImpellerContext MetalSurfaceIOS::CreateContext() {
  if (!impl_->device) return nullptr;
  return ImpellerContextCreateMetalNew(IMPELLER_VERSION);
}

void MetalSurfaceIOS::SetDrawableSize(int w, int h) {
  if (!impl_->layer || w <= 0 || h <= 0) return;
  const CGSize want = CGSizeMake(w, h);
  if (!CGSizeEqualToSize(want, impl_->layer.drawableSize)) impl_->layer.drawableSize = want;
}

bool MetalSurfaceIOS::Draw(ImpellerContext context, ImpellerDisplayList dl) {
  @autoreleasepool {
    impl_->DropDrawable();
    if (!impl_->layer || !context || !dl) return false;
    id<CAMetalDrawable> drawable = [impl_->layer nextDrawable];
    if (!drawable) return false;
    ImpellerSurface s = ImpellerSurfaceCreateWrappedMetalDrawableNew(context, (__bridge void*)drawable);
    if (!s) return false;
    impl_->drawable = drawable;
    impl_->surface = s;
    return ImpellerSurfaceDrawDisplayList(s, dl);
  }
}

// SDK patch 0005's ImpellerSurfaceReadPixels blits on Impeller's own queue, so
// the copy is ordered after the draw (MetalSurface.mm predates the patch and
// spies on the queue instead).
bool MetalSurfaceIOS::ReadPixels(std::vector<Px>* out, int* w, int* h) {
  if (!impl_->surface) return false;
  ImpellerISize size = {};
  if (!ImpellerSurfaceGetSize(impl_->surface, &size) || size.width <= 0 || size.height <= 0) {
    return false;
  }
  const size_t n = (size_t)size.width * (size_t)size.height;
  std::vector<uint8_t> raw(n * 4);
  ImpellerReadbackLayout layout = kImpellerReadbackLayoutBGRA8888;
  if (!ImpellerSurfaceReadPixels(impl_->surface, raw.data(), raw.size(), &layout)) return false;
  const bool bgra = layout == kImpellerReadbackLayoutBGRA8888;
  out->resize(n);
  for (size_t i = 0; i < n; ++i) {
    const uint8_t* p = &raw[i * 4];
    (*out)[i] = bgra ? Px{p[2], p[1], p[0], p[3]} : Px{p[0], p[1], p[2], p[3]};
  }
  *w = (int)size.width;
  *h = (int)size.height;
  return true;
}

void MetalSurfaceIOS::Present(std::function<void(int64_t presentedUs)> onDisplayed) {
  @autoreleasepool {
    if (!impl_->surface) return;
#if TARGET_OS_SIMULATOR
    // The simulator SDK's MTLDrawable has no addPresentedHandler/presentedTime:
    // the displayed time is unknown, reported as 0 right after the present.
    ImpellerSurfacePresent(impl_->surface);
    if (onDisplayed) onDisplayed(0);
#else
    if (onDisplayed) {
      [impl_->drawable addPresentedHandler:^(id<MTLDrawable> d) {
        const CFTimeInterval t = d.presentedTime;
        onDisplayed(t > 0 ? DisplayLinkIOS::HostSecondsToSteadyUs(t) : 0);
      }];
    }
    ImpellerSurfacePresent(impl_->surface);
#endif
    impl_->presents.fetch_add(1, std::memory_order_relaxed);
    impl_->DropDrawable();
  }
}

void MetalSurfaceIOS::SetDisplaySync(bool on) { impl_->displaySync.store(on); }
bool MetalSurfaceIOS::displaySync() const { return impl_->displaySync.load(); }

void MetalSurfaceIOS::Release() {
  @autoreleasepool {
    impl_->DropDrawable();
  }
}

int MetalSurfaceIOS::presents() const { return impl_->presents.load(); }

}  // namespace rni
