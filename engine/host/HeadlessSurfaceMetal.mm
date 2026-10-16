// FP-23: HeadlessSurface on native Metal (darwin `--headless --backend metal`).
// Compiled with -fobjc-arc (engine/CMakeLists.txt). The render target is an
// offscreen BGRA8 MTLTexture wrapped by SDK patch 0005
// (ImpellerSurfaceCreateWrappedMetalTextureNew -> SurfaceMTL::MakeFromTexture,
// the FlutterMetalTexture path of flutter/shell/gpu/gpu_surface_metal_impeller.mm),
// so a headless frame gets the same 4x MSAA + resolve as a windowed drawable.
// Readback is patch 0005's ImpellerSurfaceReadPixels: a blit on Impeller's own
// queue, waited on (flutter/lib/ui/painting/image_encoding_impeller.cc).
#include "host/HeadlessSurface.h"

#if RNI_HEADLESS_METAL
#import <Metal/Metal.h>

#include <cstdio>
#include <cstdlib>

#include "base/ContextFlags.h"
#include "fabric/ImageStore.h"
#include "host/RecordNoGl.h"
#include "text/TypographyContexts.h"

static_assert(__has_feature(objc_arc), "HeadlessSurfaceMetal.mm must be built with -fobjc-arc");

namespace rni {

namespace {
// MTLGPUFamilyApple3+ / Mac2: 16384 for 2D textures (same as GlfwSurfaceMetal.cpp).
constexpr int kMetalMaxTexture2D = 16384;
}  // namespace

bool HeadlessSurface::initMetal(std::string* error) {
  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };
  // ImpellerContextCreateMetalNew uses the system default device; the texture
  // must come from the same one (impeller.h).
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) return fail("metal: MTLCreateSystemDefaultDevice returned nil");
  rni::image::SetMaxTextureSize(kMetalMaxTexture2D);
  rni::contextflags::ApplyBeforeCreate();  // FP-22
  context_ = ImpellerContextCreateMetalNew(IMPELLER_VERSION);
  rni::contextflags::Report(context_);
  if (!context_) return fail("ImpellerContextCreateMetalNew returned null");
  typography_ = ImpellerTypographyContextNew();
  if (!typography_) return fail("ImpellerTypographyContextNew returned null");
  rni::typography::Bind(typography_);  // FP-12
  // No GL context exists on this path: the FP-14 assert holds trivially.
  rni::recordgl::ContextHooks h;
  h.release = [] { return true; };
  h.acquire = [] { return true; };
  h.isCurrent = [] { return false; };
  rni::recordgl::SetContextHooks(std::move(h));

  if (const char* f = std::getenv("RNI_FORCE_FBO_FAIL"); f != nullptr && f[0] == '1') {
    fprintf(stderr, "rn-impeller: WARN: main FBO unavailable (RNI_FORCE_FBO_FAIL) — degrading to "
                    "count-only, no pixels this run\n");
    return true;  // same degraded contract as the GL path
  }
  MTLTextureDescriptor* desc =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                         width:(NSUInteger)width_
                                                        height:(NSUInteger)height_
                                                     mipmapped:NO];
  desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  desc.storageMode = MTLStorageModePrivate;
  id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
  if (!texture) return fail("metal: offscreen texture allocation failed");
  surface_ = ImpellerSurfaceCreateWrappedMetalTextureNew(context_, (__bridge void*)texture);
  if (!surface_) return fail("ImpellerSurfaceCreateWrappedMetalTextureNew returned null");
  metalTexture_ = (__bridge_retained void*)texture;
  std::printf("rn-impeller: metal_offscreen ok=1 texture=%lux%lu pixel_format=%s device=%s\n",
              (unsigned long)texture.width, (unsigned long)texture.height,
              texture.pixelFormat == MTLPixelFormatBGRA8Unorm ? "bgra8" : "other",
              [[device name] UTF8String]);
  std::fflush(stdout);
  return true;
}

bool HeadlessSurface::readPixelsMetal(std::vector<Px>* out) {
  const size_t n = (size_t)width_ * height_;
  std::vector<uint8_t> raw(n * 4);
  ImpellerReadbackLayout layout = kImpellerReadbackLayoutRGBA8888;
  if (!ImpellerSurfaceReadPixels(surface_, raw.data(), raw.size(), &layout)) return false;
  // Top-left origin already (Metal); only the byte order differs from Px.
  const bool bgra = layout == kImpellerReadbackLayoutBGRA8888;
  out->resize(n);
  for (size_t i = 0; i < n; ++i) {
    const uint8_t* p = &raw[i * 4];
    (*out)[i] = bgra ? Px{p[2], p[1], p[0], p[3]} : Px{p[0], p[1], p[2], p[3]};
  }
  static bool printed = false;
  if (!printed) {
    printed = true;
    std::printf("rn-impeller: metal_readback layout=%s bytes=%zu\n", bgra ? "bgra8" : "rgba8", raw.size());
    std::fflush(stdout);
  }
  return true;
}

void HeadlessSurface::releaseMetal() {
  if (!metalTexture_) return;
  id<MTLTexture> texture = (__bridge_transfer id<MTLTexture>)metalTexture_;
  metalTexture_ = nullptr;
  (void)texture;  // ARC releases it here
}

}  // namespace rni
#endif  // RNI_HEADLESS_METAL
