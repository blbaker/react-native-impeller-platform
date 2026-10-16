// FP-21: GlfwSurface's native Metal GPU half (darwin). The window, input and
// typography stay in GlfwSurface.cpp; MetalSurface owns the layer + drawable.
#if defined(__APPLE__)
#include <cstdio>

#include "base/ContextFlags.h"
#include "fabric/ImageStore.h"
#include "host/GlfwSurface.h"
#include "host/MetalSurface.h"
#include "host/RasterThread.h"
#include "host/RecordNoGl.h"

namespace rni {

namespace {
// MTLGPUFamilyApple3+ / Mac2: 16384 for 2D textures (Metal feature set tables).
constexpr int kMetalMaxTexture2D = 16384;
}  // namespace

bool GlfwSurface::initGpuMetal(bool rasterThread, std::string* error) {
  (void)rasterThread;
  rni::image::SetMaxTextureSize(kMetalMaxTexture2D);
  rni::contextflags::ApplyBeforeCreate();  // FP-22
  context_ = metal_->CreateContext();
  rni::contextflags::Report(context_);
  if (!context_) {
    if (error) *error = "ImpellerContextCreateMetalNew returned null";
    return false;
  }
  gpuWidth_ = width_;
  gpuHeight_ = height_;
  metal_->SetDrawableSize(gpuWidth_, gpuHeight_);
  // No GL context exists on this path: RECORD has nothing to release, and the
  // FP-14 assert ("no context current in RECORD") holds trivially.
  rni::recordgl::ContextHooks h;
  h.release = [] { return true; };
  h.acquire = [] { return true; };
  h.isCurrent = [] { return false; };
  rni::recordgl::SetContextHooks(std::move(h));
  std::printf("rn-impeller: metal_context ok=1 drawable=%dx%d\n", gpuWidth_, gpuHeight_);
  std::fflush(stdout);
  return true;
}

void GlfwSurface::releaseGpuMetal() {
  std::printf("rn-impeller: gpu_release gl_current=0 backend=metal tid=%lld\n",
              rni::CurrentThreadTag());
  std::printf("rn-impeller: metal_present presents=%d transaction_presents=%d\n",
              metal_->presents(), metal_->transactionPresents());
  std::fflush(stdout);
  rni::recordgl::SetContextHooks({});
  metal_->Release();  // the drawable's surface before its context
  if (context_) ImpellerContextRelease(context_);
  context_ = nullptr;
}

}  // namespace rni
#endif  // __APPLE__
