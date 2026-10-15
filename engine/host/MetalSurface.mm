// FP-21: see MetalSurface.h. Compiled with -fobjc-arc (engine/CMakeLists.txt).
#include "host/MetalSurface.h"

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include <atomic>

#include "host/DisplayLinkDarwin.h"
#include <cstdio>

#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3.h>
#include <GLFW/glfw3native.h>

static_assert(__has_feature(objc_arc), "MetalSurface.mm must be built with -fobjc-arc");

namespace rni {

namespace {
// ⛔ A capture blit on our OWN queue is not ordered after Impeller's render:
// the first frame read back black without a 200 ms settle (measured). Command
// buffers are ordered only within one queue, and the interop API exposes no
// ContextMTL::FinishQueue. Impeller makes exactly one queue, with
// device.newCommandQueue (impeller/renderer/backend/metal/context_mtl.mm), so
// that call is observed once, during ImpellerContextCreateMetalNew, and the
// capture blit is encoded on the same queue (ordered after the draw).
typedef id (*NewQueueFn)(id, SEL) __attribute__((ns_returns_retained));
NewQueueFn gOrigNewQueue = nullptr;
id gSpyDevice = nil;
id gSpiedQueue = nil;

id SpyNewCommandQueue(id self, SEL cmd) __attribute__((ns_returns_retained));
id SpyNewCommandQueue(id self, SEL cmd) {
  id queue = gOrigNewQueue(self, cmd);
  if (self == gSpyDevice && gSpiedQueue == nil) gSpiedQueue = queue;
  return queue;
}

// Runs create() and returns the first queue it made on `device` (nil if none).
id<MTLCommandQueue> ObserveNewQueue(id<MTLDevice> device, ImpellerContext* out,
                                    ImpellerContext (^create)(void)) {
  Method m = class_getInstanceMethod(object_getClass(device), @selector(newCommandQueue));
  if (!m) {
    *out = create();
    return nil;
  }
  gSpyDevice = device;
  gSpiedQueue = nil;
  gOrigNewQueue = (NewQueueFn)method_getImplementation(m);
  method_setImplementation(m, (IMP)SpyNewCommandQueue);
  *out = create();
  method_setImplementation(m, (IMP)gOrigNewQueue);
  id<MTLCommandQueue> q = gSpiedQueue;
  gSpiedQueue = nil;
  gSpyDevice = nil;
  return q;
}
}  // namespace

struct MetalSurface::Impl {
  __weak NSWindow* window = nil;
  CAMetalLayer* layer = nil;
  id<MTLDevice> device = nil;
  id<MTLCommandQueue> readQueue = nil;  // Impeller's own queue (ObserveNewQueue)
  id<CAMetalDrawable> drawable = nil;   // acquired by Draw, dropped by Present
  ImpellerSurface surface = nullptr;
  bool layerTransaction = false;        // raster thread's view of presentsWithTransaction
  std::atomic<bool> liveResize{false};  // written on main (SyncFromWindow)
  std::atomic<int> presents{0};
  std::atomic<int> txPresents{0};
  bool damaged = false;                 // main thread only
  std::function<void()> onDamage;       // main thread only
  CFRunLoopObserverRef observer = nullptr;

  void DropDrawable() {
    if (surface) ImpellerSurfaceRelease(surface);
    surface = nullptr;
    drawable = nil;
  }

  // Blocks until every GPU write to the drawable committed so far is done: a
  // blit that reads it, on Impeller's queue (so after the draw), waited on.
  bool CopyDrawable(id<MTLBuffer> buf, NSUInteger w, NSUInteger h) {
    id<MTLCommandBuffer> cb = [readQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:drawable.texture
               sourceSlice:0
               sourceLevel:0
              sourceOrigin:MTLOriginMake(0, 0, 0)
                sourceSize:MTLSizeMake(w, h, 1)
                  toBuffer:buf
         destinationOffset:0
    destinationBytesPerRow:w * 4
  destinationBytesPerImage:w * h * 4];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return cb.status == MTLCommandBufferStatusCompleted;
  }
};

MetalSurface::MetalSurface() : impl_(std::make_unique<Impl>()) {}
MetalSurface::~MetalSurface() {
  if (impl_->observer) {
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), impl_->observer, kCFRunLoopCommonModes);
    CFRelease(impl_->observer);
  }
  Release();
}

void MetalSurface::SetDamageHandler(std::function<void()> onDamage) {
  impl_->onDamage = std::move(onDamage);
  if (impl_->observer) return;
  Impl* impl = impl_.get();
  impl_->observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, 0,
      ^(CFRunLoopObserverRef, CFRunLoopActivity) {
        if (!impl->damaged || !impl->onDamage) return;
        impl->damaged = false;
        impl->onDamage();
      });
  CFRunLoopAddObserver(CFRunLoopGetMain(), impl_->observer, kCFRunLoopCommonModes);
}

void MetalSurface::MarkDamage() { impl_->damaged = true; }

bool MetalSurface::Attach(GLFWwindow* window, std::string* error) {
  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };
  NSWindow* nsWindow = glfwGetCocoaWindow(window);
  NSView* view = nsWindow ? [nsWindow contentView] : nil;
  if (!view) return fail("metal: no Cocoa content view");
  // ImpellerContextCreateMetalNew uses the system default device; the layer
  // must hand out drawables from the same one (impeller.h).
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) return fail("metal: MTLCreateSystemDefaultDevice returned nil");
  CAMetalLayer* layer = [CAMetalLayer layer];
  layer.device = device;
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  // Flutter: framebufferOnly NO when the surface data must stay readable
  // (ios_surface_metal_impeller.mm, kSurfaceDataAccessible); our captures read it.
  layer.framebufferOnly = NO;
  layer.contentsScale = [nsWindow backingScaleFactor];
  // Layer-hosting view, as GLFW's own Metal/Vulkan surface does
  // (glfw cocoa_window.m _glfwCreateWindowSurfaceCocoa).
  [view setLayer:layer];
  [view setWantsLayer:YES];
  const CGSize pts = view.bounds.size;
  layer.drawableSize = CGSizeMake(pts.width * layer.contentsScale, pts.height * layer.contentsScale);
  impl_->window = nsWindow;
  impl_->layer = layer;
  impl_->device = device;
  std::printf("rn-impeller: layer contents_scale=%.2f backing_scale=%.2f\n", layer.contentsScale,
              [nsWindow backingScaleFactor]);
  std::printf("rn-impeller: metal_layer pixel_format=%s framebuffer_only=%d contents_scale=%.2f "
              "drawable=%.0fx%.0f device=%s\n",
              layer.pixelFormat == MTLPixelFormatBGRA8Unorm ? "bgra8" : "other",
              layer.framebufferOnly ? 1 : 0, layer.contentsScale, layer.drawableSize.width,
              layer.drawableSize.height, [[device name] UTF8String]);
  std::fflush(stdout);
  return true;
}

void MetalSurface::SyncFromWindow() {
  NSWindow* w = impl_->window;
  if (!w || !impl_->layer) return;
  impl_->layer.contentsScale = [w backingScaleFactor];
  impl_->liveResize.store([w inLiveResize], std::memory_order_release);
}

ImpellerContext MetalSurface::CreateContext() {
  ImpellerContext ctx = nullptr;
  impl_->readQueue = ObserveNewQueue(impl_->device, &ctx, ^ImpellerContext {
    return ImpellerContextCreateMetalNew(IMPELLER_VERSION);
  });
  std::printf("rn-impeller: metal_capture_queue shared=%d\n", impl_->readQueue ? 1 : 0);
  std::fflush(stdout);
  if (!impl_->readQueue && ctx) {  // no ordered capture queue = no Metal
    ImpellerContextRelease(ctx);
    ctx = nullptr;
  }
  return ctx;
}

void MetalSurface::SetDrawableSize(int w, int h) {
  if (!impl_->layer || w <= 0 || h <= 0) return;
  const CGSize want = CGSizeMake(w, h);
  if (!CGSizeEqualToSize(want, impl_->layer.drawableSize)) impl_->layer.drawableSize = want;
}

bool MetalSurface::Draw(ImpellerContext context, ImpellerDisplayList dl) {
  @autoreleasepool {
    impl_->DropDrawable();
    if (!impl_->layer || !context) return false;
    id<CAMetalDrawable> drawable = [impl_->layer nextDrawable];  // WaitForNextDrawable
    if (!drawable) return false;
    ImpellerSurface s = ImpellerSurfaceCreateWrappedMetalDrawableNew(context, (__bridge void*)drawable);
    if (!s) return false;
    impl_->drawable = drawable;
    impl_->surface = s;
    return ImpellerSurfaceDrawDisplayList(s, dl);
  }
}

bool MetalSurface::ReadPixels(std::vector<Px>* out, int* w, int* h) {
  @autoreleasepool {
    if (!impl_->drawable) return false;
    id<MTLTexture> tex = impl_->drawable.texture;
    const NSUInteger tw = tex.width, th = tex.height;
    id<MTLBuffer> buf = [impl_->device newBufferWithLength:tw * th * 4
                                                   options:MTLResourceStorageModeShared];
    if (!buf || !impl_->CopyDrawable(buf, tw, th)) return false;
    const uint8_t* src = static_cast<const uint8_t*>([buf contents]);
    out->resize(tw * th);
    for (NSUInteger i = 0; i < tw * th; ++i) {  // BGRA8 -> RGBA
      (*out)[i] = Px{src[i * 4 + 2], src[i * 4 + 1], src[i * 4 + 0], src[i * 4 + 3]};
    }
    *w = (int)tw;
    *h = (int)th;
    return true;
  }
}

void MetalSurface::Present(std::function<void(int64_t presentedUs)> onDisplayed) {
  @autoreleasepool {
    if (!impl_->surface) return;
    if (onDisplayed) {
      // FP-27: displayed time, read back from the drawable (Flutter's
      // FlutterMetalLayer drawables carry presentedTime the same way).
      [impl_->drawable addPresentedHandler:^(id<MTLDrawable> d) {
        const CFTimeInterval t = d.presentedTime;
        onDisplayed(t > 0 ? DisplayLinkDarwin::HostSecondsToSteadyUs(t) : 0);
      }];
    }
    const bool tx = impl_->liveResize.load(std::memory_order_acquire);
    if (tx != impl_->layerTransaction) {
      impl_->layer.presentsWithTransaction = tx;
      impl_->layerTransaction = tx;
    }
    if (tx) {
      // SurfaceMTL::Present's present_with_transaction branch (wait, then
      // [drawable present] in a CA transaction). The interop API has no
      // PresentWithTransaction, so the wait is our own blit of one pixel.
      id<MTLBuffer> px = [impl_->device newBufferWithLength:4 options:MTLResourceStorageModeShared];
      impl_->CopyDrawable(px, 1, 1);
      [CATransaction begin];
      [impl_->drawable present];
      [CATransaction commit];
      impl_->txPresents.fetch_add(1, std::memory_order_relaxed);
    } else {
      ImpellerSurfacePresent(impl_->surface);
    }
    impl_->presents.fetch_add(1, std::memory_order_relaxed);
    impl_->DropDrawable();
  }
}

void MetalSurface::SetDisplaySync(bool on) {
  if (impl_->layer) impl_->layer.displaySyncEnabled = on;
}

void MetalSurface::Release() {
  @autoreleasepool {
    impl_->DropDrawable();
  }
}

uint32_t MetalSurface::DisplayId() const {
  NSScreen* screen = impl_->window ? [impl_->window screen] : nil;
  NSNumber* n = screen ? [screen deviceDescription][@"NSScreenNumber"] : nil;
  return n ? (uint32_t)[n unsignedIntValue] : 0;
}

int MetalSurface::presents() const { return impl_->presents.load(); }
int MetalSurface::transactionPresents() const { return impl_->txPresents.load(); }

}  // namespace rni
