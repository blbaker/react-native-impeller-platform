// FP-14 raster-side GPU jobs. See RasterJobs.h.
#include "scenegraph/RasterJobs.h"

#include <algorithm>

#include "base/Trace.h"

#if !defined(__ANDROID__)
#define RNI_RASTER_JOBS_GL 1
#include "scenegraph/SceneGraphGl.h"  // last: gl* are macros on Windows
#else
#define RNI_RASTER_JOBS_GL 0
#endif

namespace rni {

namespace {
std::atomic<uint64_t> gUploads{0}, gOffscreens{0}, gFailed{0};
}  // namespace

RasterJobs::Totals RasterJobs::totals() {
  return {gUploads.load(), gOffscreens.load(), gFailed.load()};
}

struct RasterJobs::Job {
  bool offscreen = false;
  JobFlag flag = std::make_shared<std::atomic<int>>(kJobPending);
  ImpellerTexture texture = nullptr;  // retained
  uint32_t name = 0;
  int w = 0, h = 0;
  // upload
  const uint8_t* rgba = nullptr;
  std::shared_ptr<const void> keep;
  bool allocate = false, clampEdges = false, image = false;
  // offscreen
  ImpellerDisplayList dl = nullptr;  // owned
  std::vector<std::pair<int, int>> hops;
};

uint32_t GlNamePool::Take() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (free_.empty()) {
    starved_.fetch_add(1, std::memory_order_relaxed);
    return 0;
  }
  const uint32_t n = free_.back();
  free_.pop_back();
  ++takenSinceRefill_;
  return n;
}

void GlNamePool::Refill() {
#if RNI_RASTER_JOBS_GL
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

RasterJobs::RasterJobs(ImpellerContext context, std::shared_ptr<GlNamePool> pool)
    : context_(context), pool_(std::move(pool)) {}

RasterJobs::~RasterJobs() {
  for (Job& j : jobs_) {
    if (!ran_) j.flag->store(kJobFailed);  // dropped frame: dependents redo it
    if (j.texture) ImpellerTextureRelease(j.texture);
    if (j.dl) ImpellerDisplayListRelease(j.dl);
  }
}

ImpellerTexture RasterJobs::WrapNewName(int w, int h, uint32_t* name) {
  *name = 0;
  if (w <= 0 || h <= 0) return nullptr;
  const uint32_t n = pool_->Take();
  if (n == 0) return nullptr;
  ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888, {w, h}, 1};
  // Ownership of the name moves to Impeller (it deletes it on the last release).
  ImpellerTexture t = ImpellerTextureCreateWithOpenGLTextureHandleNew(context_, &desc, n);
  if (t) *name = n;
  return t;
}

JobFlag RasterJobs::AddUpload(ImpellerTexture texture, uint32_t name, int w, int h,
                              const uint8_t* rgba, std::shared_ptr<const void> keep,
                              bool allocate, bool clampEdges, bool image) {
  Job j;
  ImpellerTextureRetain(texture);
  j.texture = texture;
  j.name = name;
  j.w = w;
  j.h = h;
  j.rgba = rgba;
  j.keep = std::move(keep);
  j.allocate = allocate;
  j.clampEdges = clampEdges;
  j.image = image;
  jobs_.push_back(std::move(j));
  return jobs_.back().flag;
}

JobFlag RasterJobs::AddOffscreen(ImpellerDisplayList dl, int startW, int startH,
                                 std::vector<std::pair<int, int>> hops, uint32_t finalName,
                                 ImpellerTexture finalTexture) {
  Job j;
  j.offscreen = true;
  ImpellerTextureRetain(finalTexture);
  j.texture = finalTexture;
  j.name = finalName;
  j.dl = dl;
  j.w = startW;
  j.h = startH;
  j.hops = std::move(hops);
  jobs_.push_back(std::move(j));
  return jobs_.back().flag;
}

size_t RasterJobs::size() const { return jobs_.size(); }

std::vector<std::pair<int, int>> RasterJobs::HalveChain(int w, int h, int nativeW, int nativeH) {
  std::vector<std::pair<int, int>> out;
  int guard = 0;
  while ((w > nativeW * 2 || h > nativeH * 2) && guard++ < 16) {
    w = std::max(nativeW, w / 2);
    h = std::max(nativeH, h / 2);
    out.emplace_back(w, h);
  }
  return out;
}

void RasterJobs::Run() {
  if (jobs_.empty()) {
    ran_ = true;
    return;
  }
  TRACE_EVENT1("raster", "RasterJobs", "jobs", (uint64_t)jobs_.size());
  for (Job& j : jobs_) {
    const bool ok = j.offscreen ? RunOffscreen(j) : RunUpload(j);
    j.flag->store(ok ? kJobDone : kJobFailed);
    (j.offscreen ? gOffscreens : gUploads).fetch_add(1, std::memory_order_relaxed);
    if (!ok) gFailed.fetch_add(1, std::memory_order_relaxed);
    if (j.texture) ImpellerTextureRelease(j.texture);
    j.texture = nullptr;
    if (j.dl) ImpellerDisplayListRelease(j.dl);
    j.dl = nullptr;
    j.keep.reset();
  }
  ran_ = true;
}

#if RNI_RASTER_JOBS_GL
namespace {

// A w x h RGBA8 colour texture with linear filtering; `name` 0 = a fresh one.
GLuint AllocColor(GLuint name, int w, int h) {
  if (name == 0) glGenTextures(1, &name);
  glBindTexture(GL_TEXTURE_2D, name);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  return name;
}

// Draws `dl` into colour texture `color` (w x h) through a temporary FBO.
// Depth+stencil when the list has path fills: Impeller's concave fills are
// stencil-then-cover and paint their bounding box without one. Saves and
// restores the FBO binding and viewport the surface relies on.
bool DrawToColor(ImpellerContext ctx, ImpellerDisplayList dl, GLuint color, int w, int h,
                 bool depthStencil) {
  GLint prevFbo = 0;
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
  GLint prevViewport[4] = {0, 0, 0, 0};
  glGetIntegerv(GL_VIEWPORT, prevViewport);
  GLuint fbo = 0, ds = 0;
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color, 0);
  if (depthStencil) {
    glGenRenderbuffers(1, &ds);
    glBindRenderbuffer(GL_RENDERBUFFER, ds);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, w, h);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, ds);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, ds);
  }
  bool ok = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  if (ok) {
    ImpellerISize size = {w, h};
    ImpellerSurface surf =
        ImpellerSurfaceCreateWrappedFBONew(ctx, fbo, kImpellerPixelFormatRGBA8888, &size);
    ok = surf != nullptr && ImpellerSurfaceDrawDisplayList(surf, dl);
    if (ok) glFinish();
    if (surf) ImpellerSurfaceRelease(surf);
  }
  glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prevFbo);
  glDeleteFramebuffers(1, &fbo);
  if (ds) glDeleteRenderbuffers(1, &ds);
  glViewport(prevViewport[0], prevViewport[1], prevViewport[2], prevViewport[3]);
  return ok;
}

// One exact 2x box average of `src` into `color`. Y-flipped: `src` is an FBO
// colour attachment (bottom-left origin) and DrawTextureRect samples top-left,
// so every FBO-texture hop flips (a negative-height srcRect does not).
bool HalveInto(ImpellerContext ctx, ImpellerTexture src, int srcW, int srcH, GLuint color,
               int dstW, int dstH) {
  ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
  ImpellerRect srcRect = {0, 0, (float)srcW, (float)srcH};
  ImpellerRect dstRect = {0, 0, (float)dstW, (float)dstH};
  ImpellerDisplayListBuilderSave(b);
  ImpellerDisplayListBuilderTranslate(b, 0, (float)dstH);
  ImpellerDisplayListBuilderScale(b, 1.0f, -1.0f);
  ImpellerDisplayListBuilderDrawTextureRect(b, src, &srcRect, &dstRect,
                                            kImpellerTextureSamplingLinear, nullptr);
  ImpellerDisplayListBuilderRestore(b);
  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);
  ImpellerDisplayListBuilderRelease(b);
  if (!dl) return false;
  const bool ok = DrawToColor(ctx, dl, color, dstW, dstH, /*depthStencil=*/false);
  ImpellerDisplayListRelease(dl);
  return ok;
}

ImpellerTexture Adopt(ImpellerContext ctx, GLuint name, int w, int h) {
  ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888, {w, h}, 1};
  return ImpellerTextureCreateWithOpenGLTextureHandleNew(ctx, &desc, (uint64_t)name);
}

}  // namespace

bool RasterJobs::RunUpload(Job& j) {
  TRACE_EVENT0(j.image ? "image" : "raster", j.image ? "ImageUpload" : "TextureUpload");
  glBindTexture(GL_TEXTURE_2D, j.name);
  if (j.allocate) {
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, j.w, j.h, 0, GL_RGBA, GL_UNSIGNED_BYTE, j.rgba);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    if (j.clampEdges) {
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
  } else {
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, j.w, j.h, GL_RGBA, GL_UNSIGNED_BYTE, j.rgba);
  }
  return true;
}

bool RasterJobs::RunOffscreen(Job& j) {
  TRACE_EVENT0("raster", "Offscreen");
  // Stage 0 renders the list at full size; the last stage lands in j.name.
  const bool direct = j.hops.empty();
  GLuint color = AllocColor(direct ? j.name : 0, j.w, j.h);
  if (!DrawToColor(context_, j.dl, color, j.w, j.h, /*depthStencil=*/true)) {
    if (!direct) glDeleteTextures(1, &color);
    return false;
  }
  if (direct) return true;
  ImpellerTexture cur = Adopt(context_, color, j.w, j.h);
  if (cur == nullptr) return false;
  int curW = j.w, curH = j.h;
  for (size_t i = 0; i < j.hops.size(); ++i) {
    const bool last = i + 1 == j.hops.size();
    const auto [nW, nH] = j.hops[i];
    GLuint dst = AllocColor(last ? j.name : 0, nW, nH);
    const bool ok = HalveInto(context_, cur, curW, curH, dst, nW, nH);
    ImpellerTextureRelease(cur);  // done with this level
    cur = nullptr;
    if (!ok) {
      if (!last) glDeleteTextures(1, &dst);
      return false;
    }
    if (!last) {
      cur = Adopt(context_, dst, nW, nH);
      if (cur == nullptr) return false;
    }
    curW = nW;
    curH = nH;
  }
  return true;
}
#else
bool RasterJobs::RunUpload(Job&) { return false; }
bool RasterJobs::RunOffscreen(Job&) { return false; }
#endif

}  // namespace rni
