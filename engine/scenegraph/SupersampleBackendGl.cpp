// FP-20 GL supersample backend: the offscreen render + halve chain the root
// and per-<Svg> supersample hooks queue (FP-14 jobs). GL only: a GL root is
// wrapped at 1 sample (impeller/renderer/backend/gles/surface_gles.cc), while
// Metal and Vulkan resolve a 4x MSAA target into the drawable
// (backend/metal/surface_mtl.mm), so those backends have no SupersampleBackend.
#include "scenegraph/GpuBackendGl.h"

#include "base/Trace.h"

#if !defined(__ANDROID__)
#define RNI_SUPERSAMPLE_GL 1
#include "scenegraph/SceneGraphGl.h"  // last: gl* are macros on Windows
#else
#define RNI_SUPERSAMPLE_GL 0
#endif

namespace rni {

#if RNI_SUPERSAMPLE_GL
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

struct OffscreenPayload {
  ImpellerContext ctx = nullptr;
  ImpellerDisplayList dl = nullptr;  // owned
  ImpellerTexture target = nullptr;  // retained so its name is not collected first
  GLuint name = 0;
  int w = 0, h = 0;
  std::vector<std::pair<int, int>> hops;
  ~OffscreenPayload() {
    if (dl) ImpellerDisplayListRelease(dl);
    if (target) ImpellerTextureRelease(target);
  }
};

bool RunOffscreen(const OffscreenPayload& j) {
  TRACE_EVENT0("raster", "Offscreen");
  // Stage 0 renders the list at full size; the last stage lands in j.name.
  const bool direct = j.hops.empty();
  GLuint color = AllocColor(direct ? j.name : 0, j.w, j.h);
  if (!DrawToColor(j.ctx, j.dl, color, j.w, j.h, /*depthStencil=*/true)) {
    if (!direct) glDeleteTextures(1, &color);
    return false;
  }
  if (direct) return true;
  ImpellerTexture cur = Adopt(j.ctx, color, j.w, j.h);
  if (cur == nullptr) return false;
  int curW = j.w, curH = j.h;
  for (size_t i = 0; i < j.hops.size(); ++i) {
    const bool last = i + 1 == j.hops.size();
    const auto [nW, nH] = j.hops[i];
    GLuint dst = AllocColor(last ? j.name : 0, nW, nH);
    const bool ok = HalveInto(j.ctx, cur, curW, curH, dst, nW, nH);
    ImpellerTextureRelease(cur);  // done with this level
    cur = nullptr;
    if (!ok) {
      if (!last) glDeleteTextures(1, &dst);
      return false;
    }
    if (!last) {
      cur = Adopt(j.ctx, dst, nW, nH);
      if (cur == nullptr) return false;
    }
    curW = nW;
    curH = nH;
  }
  return true;
}

class GlSupersample final : public SupersampleBackend {
 public:
  GlSupersample(ImpellerContext ctx, std::shared_ptr<GlNamePool> pool)
      : ctx_(ctx), pool_(std::move(pool)) {}
  const char* name() const override { return "gl"; }

  ImpellerTexture Target(RasterJobs* jobs, int texW, int texH, uint64_t* handle) override {
    *handle = 0;
    if (jobs == nullptr) return nullptr;
    uint32_t name = 0;
    ImpellerTexture t = WrapNewGlName(ctx_, *pool_, texW, texH, &name);
    if (t) {
      *handle = name;
      CountOffscreenTarget();
    }
    return t;
  }

  JobFlag Render(RasterJobs* jobs, ImpellerDisplayList dl, int pxW, int pxH,
                 std::vector<std::pair<int, int>> hops, uint64_t handle,
                 ImpellerTexture target) override {
    auto p = std::make_shared<OffscreenPayload>();
    p->ctx = ctx_;
    p->dl = dl;
    ImpellerTextureRetain(target);
    p->target = target;
    p->name = (GLuint)handle;
    p->w = pxW;
    p->h = pxH;
    p->hops = std::move(hops);
    return jobs->Add(RasterJobs::Kind::kOffscreen, [p] { return RunOffscreen(*p); });
  }

 private:
  ImpellerContext ctx_;
  std::shared_ptr<GlNamePool> pool_;
};

}  // namespace

std::unique_ptr<SupersampleBackend> MakeGlSupersample(ImpellerContext ctx,
                                                      std::shared_ptr<GlNamePool> pool) {
  return std::make_unique<GlSupersample>(ctx, std::move(pool));
}

bool GlPrewarmDraw(ImpellerContext ctx, ImpellerDisplayList dl) {
  TRACE_EVENT0("raster", "PrewarmTour");
  GLuint color = AllocColor(0, 1, 1);
  const bool ok = DrawToColor(ctx, dl, color, 1, 1, /*depthStencil=*/true);
  glDeleteTextures(1, &color);
  return ok;
}
#else
bool GlPrewarmDraw(ImpellerContext, ImpellerDisplayList) { return false; }


std::unique_ptr<SupersampleBackend> MakeGlSupersample(ImpellerContext,
                                                      std::shared_ptr<GlNamePool>) {
  return nullptr;
}
#endif

}  // namespace rni
