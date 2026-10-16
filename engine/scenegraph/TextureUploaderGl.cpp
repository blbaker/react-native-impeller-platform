// FP-20 GL backend: texture uploads (FP-14's name trick) and the backend's
// assembly. See GpuBackendGl.h. Model: image_decoder_impeller.cc:730-737,
// where GLES alone hands uploads to the thread that owns a GL context.
#include "scenegraph/GpuBackendGl.h"

#include <algorithm>

#include "base/Trace.h"

#if !defined(__ANDROID__)
#define RNI_TEXTURE_GL 1
#include "scenegraph/SceneGraphGl.h"  // last: gl* are macros on Windows
#else
#define RNI_TEXTURE_GL 0
#endif

namespace rni {

uint32_t GlNamePool::Take() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (free_.empty()) {
    CountStarved();
    return 0;
  }
  const uint32_t n = free_.back();
  free_.pop_back();
  ++takenSinceRefill_;
  return n;
}

void GlNamePool::Refill() {
#if RNI_TEXTURE_GL
  std::lock_guard<std::mutex> lock(mutex_);
  peakTaken_ = std::max(peakTaken_, takenSinceRefill_);
  takenSinceRefill_ = 0;
  const size_t target = std::max(kMinFree, 2 * peakTaken_);
  if (free_.size() >= target) return;
  const size_t add = target - free_.size();
  const size_t at = free_.size();
  free_.resize(target);
  glGenTextures((GLsizei)add, reinterpret_cast<GLuint*>(free_.data() + at));
#endif
}

ImpellerTexture WrapNewGlName(ImpellerContext ctx, GlNamePool& pool, int w, int h,
                              uint32_t* name) {
  *name = 0;
  if (w <= 0 || h <= 0) return nullptr;
  const uint32_t n = pool.Take();
  if (n == 0) return nullptr;
  ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888, {w, h}, 1};
  // Ownership of the name moves to Impeller (it deletes it on the last release).
  ImpellerTexture t = ImpellerTextureCreateWithOpenGLTextureHandleNew(ctx, &desc, n);
  if (t) *name = n;
  return t;
}

#if RNI_TEXTURE_GL
namespace {

// Keeps the target texture (so its name is not collected first) and the CPU
// pixels alive until the raster side has copied them.
struct UploadPayload {
  ImpellerTexture texture = nullptr;
  uint32_t name = 0;
  int w = 0, h = 0;
  const uint8_t* rgba = nullptr;
  std::shared_ptr<const void> keep;
  bool allocate = false;
  UploadFlags flags;
  ~UploadPayload() {
    if (texture) ImpellerTextureRelease(texture);
  }
};

bool RunUpload(const UploadPayload& j) {
  TRACE_EVENT0(j.flags.image ? "image" : "raster", j.flags.image ? "ImageUpload" : "TextureUpload");
  glBindTexture(GL_TEXTURE_2D, j.name);
  if (j.allocate) {
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, j.w, j.h, 0, GL_RGBA, GL_UNSIGNED_BYTE, j.rgba);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    if (j.flags.clampEdges) {
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
  } else {
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, j.w, j.h, GL_RGBA, GL_UNSIGNED_BYTE, j.rgba);
  }
  return true;
}

// RECORD wraps a raster-generated name and queues the copy; the raster side
// runs glTexImage2D / glTexSubImage2D before it draws the list.
class GlNameUploader final : public TextureUploader {
 public:
  GlNameUploader(ImpellerContext ctx, std::shared_ptr<GlNamePool> pool)
      : ctx_(ctx), pool_(std::move(pool)) {}
  const char* name() const override { return "gl_name"; }
  bool deferred() const override { return true; }

  bool Upload(TextureSlot& slot, RasterJobs* jobs, int w, int h, const uint8_t* rgba,
              std::shared_ptr<const void> keep, UploadFlags flags) override {
    if (jobs == nullptr || w <= 0 || h <= 0 || rgba == nullptr) return false;
    // An upload whose frame was dropped never ran: start over with a new name.
    const bool fresh = slot.texture == nullptr || slot.handle == 0 || JobFailed(slot.job) ||
                       slot.w != w || slot.h != h;
    if (fresh) {
      // ⛔ A RESIZE NEEDS A FRESH GL NAME. Impeller owns an adopted name and
      // deletes it when the last wrapper drops; reusing it after releasing the
      // wrapper sampled a deleted texture (black terrain on Mesa, ci-world-resize).
      if (slot.texture) ImpellerTextureRelease(slot.texture);  // GL-free: marks the handle
      slot.texture = nullptr;
      slot.handle = 0;
      uint32_t name = 0;
      slot.texture = WrapNewGlName(ctx_, *pool_, w, h, &name);
      if (slot.texture == nullptr) return false;
      CountGlName();
      slot.handle = name;
      slot.w = w;
      slot.h = h;
    }
    auto p = std::make_shared<UploadPayload>();
    ImpellerTextureRetain(slot.texture);
    p->texture = slot.texture;
    p->name = (uint32_t)slot.handle;
    p->w = w;
    p->h = h;
    p->rgba = rgba;
    p->keep = std::move(keep);
    p->allocate = fresh;
    p->flags = flags;
    slot.job = jobs->Add(RasterJobs::Kind::kUpload, [p] { return RunUpload(*p); });
    return true;
  }

  ImpellerTexture AdoptIo(uint64_t handle, int w, int h) override {
    // FP-17: the IO context filled this name; wrapping it makes no GL call.
    ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888, {w, h}, 1};
    ImpellerTexture t = ImpellerTextureCreateWithOpenGLTextureHandleNew(ctx_, &desc, handle);
    if (t) CountGlName();
    return t;
  }

 private:
  ImpellerContext ctx_;
  std::shared_ptr<GlNamePool> pool_;
};

}  // namespace

GlParts MakeGlParts(ImpellerContext ctx) {
  GlParts parts;
  // Windows resolves its gl* table at first use; unresolved = no GL backend
  // (images then go through Impeller's own upload, as before FP-20).
  if (ctx == nullptr || !scenegraph_gl::Ready()) return parts;
  auto pool = std::make_shared<GlNamePool>();
  pool->Refill();  // names for the first RECORD (context current here)
  parts.uploader = std::make_unique<GlNameUploader>(ctx, pool);
  parts.supersample = MakeGlSupersample(ctx, pool);
  parts.afterRaster = [pool] { pool->Refill(); };
  parts.snapshot = MakeGlSnapshotReadback(ctx);  // FP-43
  return parts;
}
#else
GlParts MakeGlParts(ImpellerContext) { return {}; }
#endif

}  // namespace rni
