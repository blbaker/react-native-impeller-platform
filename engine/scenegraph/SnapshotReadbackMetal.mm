// ENG-47: view snapshots (RNViewShot captureRef / captureScreen) on native
// Metal: darwin windowed, and darwin headless with --backend metal.
//
// FP-43's readback (SnapshotReadbackGl.cpp) renders the recorded display list
// into a temporary FBO and reads it with glReadPixels. A Metal context has no
// FBO, so the backend had no readback at all and every capture rejected with
// "snapshots need a GL render backend on this host".
//
// Same model here (Flutter's DoMakeRasterSnapshot: the list into a fresh
// render target, then a blit to host memory), on the two primitives the Metal
// paths already use: an offscreen BGRA8 MTLTexture wrapped by SDK patch 0005
// (ImpellerSurfaceCreateWrappedMetalTextureNew, as HeadlessSurfaceMetal.mm
// does), and ImpellerSurfaceReadPixels, the readback the windowed screenshot
// (`shot PATH`, --screenshot) uses on the drawable. The wrap gives the
// offscreen the same 4x MSAA + resolve as the window, so a capture matches the
// screen. Compiled with -fobjc-arc (engine/CMakeLists.txt).
#include "scenegraph/SnapshotReadbackMetal.h"

#if RNI_SNAPSHOT_METAL
#import <Metal/Metal.h>

#include <utility>

#include "base/Trace.h"

static_assert(__has_feature(objc_arc), "SnapshotReadbackMetal.mm must be built with -fobjc-arc");

namespace rni {

namespace {

bool ReadbackMetal(ImpellerContext ctx, ImpellerDisplayList dl, int w, int h,
                   std::vector<uint8_t>* rgba) {
  TRACE_EVENT0("raster", "SnapshotReadback");
  if (ctx == nullptr || dl == nullptr || w <= 0 || h <= 0) return false;
  @autoreleasepool {
    // impeller.h: the texture must come from the device the context uses,
    // which ImpellerContextCreateMetalNew takes as the system default.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return false;
    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:(NSUInteger)w
                                                          height:(NSUInteger)h
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    if (!texture) return false;
    // A view with no background is transparent in the capture, as in
    // view-shot and the GL path: the wrapped target clears to transparent.
    ImpellerSurface surf = ImpellerSurfaceCreateWrappedMetalTextureNew(ctx, (__bridge void*)texture);
    if (!surf) return false;
    std::vector<uint8_t> raw((size_t)w * h * 4);
    ImpellerReadbackLayout layout = kImpellerReadbackLayoutRGBA8888;
    // The readback blit runs on Impeller's queue after the draw and is waited on.
    const bool ok = ImpellerSurfaceDrawDisplayList(surf, dl) &&
                    ImpellerSurfaceReadPixels(surf, raw.data(), raw.size(), &layout);
    ImpellerSurfaceRelease(surf);
    if (!ok) return false;
    // Metal is top-left already (no flip, unlike glReadPixels); only the byte
    // order can differ from the RGBA the encoder takes.
    if (layout == kImpellerReadbackLayoutBGRA8888) {
      for (size_t i = 0; i + 3 < raw.size(); i += 4) std::swap(raw[i], raw[i + 2]);
    }
    *rgba = std::move(raw);
    return true;
  }
}

}  // namespace

SnapshotReadback MakeMetalSnapshotReadback(ImpellerContext ctx) {
  return [ctx](ImpellerDisplayList dl, int w, int h, std::vector<uint8_t>* rgba) {
    return ReadbackMetal(ctx, dl, w, h, rgba);
  };
}

}  // namespace rni
#endif  // RNI_SNAPSHOT_METAL
