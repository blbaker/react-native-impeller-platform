// FP-20: what the painter needs from the GPU backend, with no GL above it.
//
// Model: Flutter keeps every backend difference below one interface.
// lib/ui/painting/image_decoder_impeller.cc:730-737 uploads on the IO runner
// for GLES ("The I/O image uploads are not threadsafe on GLES") and directly
// for Metal/Vulkan; the interop SDK keeps GL-only entry points
// (ImpellerTextureCreateWithOpenGLTextureHandleNew, wrapped FBOs) under
// impeller/toolkit/interop/backend/gles and refuses them on other contexts
// (impeller.cc ImpellerTextureCreateWithOpenGLTextureHandleNew: "Context is
// not OpenGL."). Anti-aliasing is per backend too: Metal wraps the drawable in
// a 4x MSAA target (backend/metal/surface_mtl.mm), GLES wraps FBO 0 at 1x
// (backend/gles/surface_gles.cc), so only GL needs our supersample hook.
//
// So the SceneGraph holds a RenderBackend: a TextureUploader (GL: raster-side
// upload into a pre-generated name; Metal/Vulkan: ImpellerTextureCreateWithContentsNew)
// and a SupersampleBackend (GL only; null = the surface provides MSAA).
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <utility>
#include <vector>

#include "impeller.h"
#include "scenegraph/RasterJobs.h"

namespace rni {

enum class GpuBackend { kGles, kMetal, kVulkan };
bool ParseGpuBackend(const char* s, GpuBackend* out);
const char* GpuBackendName(GpuBackend b);

// A cached texture and the backend state needed to refresh it.
struct TextureSlot {
  ImpellerTexture texture{nullptr};  // owned by the slot's cache
  int w{0}, h{0};
  uint64_t handle{0};  // backend storage handle (GL: the texture name)
  JobFlag job;         // the last deferred upload, if the backend defers
};

// True when the slot cannot be refreshed in place: never filled, its last
// deferred upload was dropped unrun, or the size changed.
inline bool SlotStale(const TextureSlot& s, int w, int h) {
  return s.texture == nullptr || JobFailed(s.job) || s.w != w || s.h != h;
}

struct UploadFlags {
  bool clampEdges{false};
  bool image{false};  // trace as ImageUpload (else TextureUpload)
};

class TextureUploader {
 public:
  virtual ~TextureUploader() = default;
  virtual const char* name() const = 0;
  // True when the pixels reach the GPU on the raster side (logged as such).
  virtual bool deferred() const = 0;
  // RECORD. Makes `slot` hold the w x h RGBA8888 `rgba`. `keep` owns the bytes
  // until the GPU has them. Same size = refresh in place where the backend can.
  // jobs: this frame's raster queue (may be null). False: no texture this frame.
  virtual bool Upload(TextureSlot& slot, RasterJobs* jobs, int w, int h, const uint8_t* rgba,
                      std::shared_ptr<const void> keep, UploadFlags flags) = 0;
  // RECORD. Wraps storage the IO thread already filled (FP-17). Null when this
  // backend has no such hand-off.
  virtual ImpellerTexture AdoptIo(uint64_t handle, int w, int h) = 0;
};

class SupersampleBackend {
 public:
  virtual ~SupersampleBackend() = default;
  virtual const char* name() const = 0;
  // RECORD. A texW x texH texture the offscreen will fill; null = paint in place.
  virtual ImpellerTexture Target(RasterJobs* jobs, int texW, int texH, uint64_t* handle) = 0;
  // RECORD. Queue: draw `dl` (adopted) at pxW x pxH, halve through `hops` and
  // leave the result in `target` (retained until the job runs).
  virtual JobFlag Render(RasterJobs* jobs, ImpellerDisplayList dl, int pxW, int pxH,
                         std::vector<std::pair<int, int>> hops, uint64_t handle,
                         ImpellerTexture target) = 0;
};

struct RenderBackend {
  GpuBackend context{GpuBackend::kGles};  // what the ImpellerContext really is
  GpuBackend policy{GpuBackend::kGles};   // whose rules the painter follows
  std::unique_ptr<TextureUploader> uploader;
  std::unique_ptr<SupersampleBackend> supersample;  // null: MSAA from the surface
  std::function<void()> afterRaster;                // RASTER, after each frame
};

// RASTER side (a GL context must be current when context == kGles). `policy`
// differs from `context` only under the RNI_TEST_BACKEND_POLICY test hook.
RenderBackend MakeRenderBackend(GpuBackend context, GpuBackend policy, ImpellerContext ctx);

// Backend pieces. GL ones (TextureUploaderGl.cpp) are empty when GL is not
// available (Android, an unresolved Windows loader table).
struct GlParts {
  std::unique_ptr<TextureUploader> uploader;
  std::unique_ptr<SupersampleBackend> supersample;
  std::function<void()> afterRaster;
};
GlParts MakeGlParts(ImpellerContext ctx);
std::unique_ptr<TextureUploader> MakeContentsUploader(ImpellerContext ctx);

// Process totals: textures that became GL names (uploads, IO adoptions,
// offscreen targets) vs Impeller-owned uploads.
struct GpuTextureCounts {
  uint64_t wrappedHandles, contents, offscreenTargets, starved;
};
GpuTextureCounts GpuTextureTotals();
void CountGlName();  // a texture now wraps a GL name (wrappedHandles)
void CountContentsUpload();
void CountOffscreenTarget();
void CountStarved();  // a backend had no storage ready for RECORD
// `gpu_textures gl_names= contents= offscreen_targets= starved=` at exit.
void PrintGpuTextureTotals();

}  // namespace rni
