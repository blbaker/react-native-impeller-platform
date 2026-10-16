// FP-20: GL backend internals shared by TextureUploaderGl.cpp and
// SupersampleBackendGl.cpp. Nothing above the GL backend includes this.
//
// FP-14's split, from two GL facts at our pin:
//   * ImpellerTextureCreateWithOpenGLTextureHandleNew only records a handle
//     (ReactorGLES::CreateHandle with an external name makes no GL call) and
//     releasing an ImpellerTexture only marks its handle for collection;
//   * a GL texture NAME (glGenTextures) has no storage until glTexImage2D.
// So RASTER pre-generates names (GlNamePool), RECORD wraps one in an
// ImpellerTexture, draws it into the display list and queues the job that
// fills it. RECORD makes no GL call.
#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

#include "impeller.h"
#include "scenegraph/GpuBackend.h"

namespace rni {

// Texture names generated on the raster side, taken by RECORD. Thread-safe.
class GlNamePool {
 public:
  // RECORD. 0 when empty: the caller falls back as if the GPU path failed.
  uint32_t Take();
  // RASTER (GL context current). Tops the pool up to twice the most names one
  // frame has taken, at least kMinFree.
  void Refill();
  static constexpr size_t kMinFree = 256;

 private:
  std::mutex mutex_;
  std::vector<uint32_t> free_;
  size_t takenSinceRefill_ = 0;
  size_t peakTaken_ = 0;
};

// RECORD. A pool name wrapped as a w x h RGBA8888 texture (Impeller owns the
// name from here and deletes it on the last release); null and *name 0 when
// the pool is empty or the wrap fails.
ImpellerTexture WrapNewGlName(ImpellerContext ctx, GlNamePool& pool, int w, int h,
                              uint32_t* name);

std::unique_ptr<SupersampleBackend> MakeGlSupersample(ImpellerContext ctx,
                                                      std::shared_ptr<GlNamePool> pool);

}  // namespace rni
