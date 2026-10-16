// FP-20 backend selection and the Impeller-owned uploader. See GpuBackend.h.
#include "scenegraph/GpuBackend.h"

#include <atomic>
#include <cstdio>
#include <cstring>

#include "base/Trace.h"

namespace rni {

namespace {
std::atomic<uint64_t> gGlNames{0}, gContents{0}, gTargets{0}, gStarved{0};

void ReleaseKeep(void* userData) { delete static_cast<std::shared_ptr<const void>*>(userData); }

// Metal / Vulkan: Impeller creates and fills the texture itself (a host-visible
// texture set from the mapping, impeller.cc ImpellerTextureCreateWithContentsNew).
// Those contexts take uploads from any thread. ⛔ Not on GLES from RECORD: the
// interop reactor only reacts on the context's thread (FP-14).
class ContentsUploader final : public TextureUploader {
 public:
  explicit ContentsUploader(ImpellerContext ctx) : ctx_(ctx) {}
  const char* name() const override { return "contents"; }
  bool deferred() const override { return false; }
  bool Upload(TextureSlot& slot, RasterJobs*, int w, int h, const uint8_t* rgba,
              std::shared_ptr<const void> keep, UploadFlags flags) override {
    if (w <= 0 || h <= 0 || rgba == nullptr) return false;
    TRACE_EVENT0(flags.image ? "image" : "raster", flags.image ? "ImageUpload" : "TextureUpload");
    ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888, {w, h}, 1};
    ImpellerMapping mapping = {rgba, (uint64_t)w * (uint64_t)h * 4, &ReleaseKeep};
    ImpellerTexture t = ImpellerTextureCreateWithContentsNew(
        ctx_, &desc, &mapping, new std::shared_ptr<const void>(std::move(keep)));
    if (t == nullptr) return false;
    CountContentsUpload();
    if (slot.texture) ImpellerTextureRelease(slot.texture);
    slot.texture = t;
    slot.w = w;
    slot.h = h;
    slot.handle = 0;
    slot.job.reset();
    return true;
  }
  ImpellerTexture AdoptIo(uint64_t, int, int) override { return nullptr; }

 private:
  ImpellerContext ctx_;
};

}  // namespace

bool ParseGpuBackend(const char* s, GpuBackend* out) {
  if (std::strcmp(s, "gles") == 0) *out = GpuBackend::kGles;
  else if (std::strcmp(s, "metal") == 0) *out = GpuBackend::kMetal;
  else if (std::strcmp(s, "vulkan") == 0) *out = GpuBackend::kVulkan;
  else return false;
  return true;
}

const char* GpuBackendName(GpuBackend b) {
  switch (b) {
    case GpuBackend::kGles: return "gles";
    case GpuBackend::kMetal: return "metal";
    case GpuBackend::kVulkan: return "vulkan";
  }
  return "?";
}

std::unique_ptr<TextureUploader> MakeContentsUploader(ImpellerContext ctx) {
  return std::make_unique<ContentsUploader>(ctx);
}

RenderBackend MakeRenderBackend(GpuBackend context, GpuBackend policy, ImpellerContext ctx) {
  RenderBackend b;
  b.context = context;
  b.policy = policy;
  if (ctx == nullptr) return b;
  GlParts gl = context == GpuBackend::kGles ? MakeGlParts(ctx) : GlParts{};
  const bool useGl = policy == GpuBackend::kGles;
  b.uploader = useGl && gl.uploader ? std::move(gl.uploader) : MakeContentsUploader(ctx);
  // Metal / Vulkan get 4x MSAA from the surface wrap: no supersample hook.
  b.supersample = useGl ? std::move(gl.supersample) : nullptr;
  b.afterRaster = std::move(gl.afterRaster);
  b.snapshot = std::move(gl.snapshot);  // GL context only (FP-43)
  return b;
}

GpuTextureCounts GpuTextureTotals() {
  return {gGlNames.load(), gContents.load(), gTargets.load(), gStarved.load()};
}
void CountGlName() { gGlNames.fetch_add(1, std::memory_order_relaxed); }
void CountContentsUpload() { gContents.fetch_add(1, std::memory_order_relaxed); }
void CountOffscreenTarget() { gTargets.fetch_add(1, std::memory_order_relaxed); }
void CountStarved() { gStarved.fetch_add(1, std::memory_order_relaxed); }

void PrintGpuTextureTotals() {
  const GpuTextureCounts c = GpuTextureTotals();
  std::printf("rn-impeller: gpu_textures gl_names=%llu contents=%llu offscreen_targets=%llu "
              "starved=%llu\n",
              (unsigned long long)c.wrappedHandles, (unsigned long long)c.contents,
              (unsigned long long)c.offscreenTargets, (unsigned long long)c.starved);
  std::fflush(stdout);
}

}  // namespace rni
