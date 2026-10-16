// FP-43 GL snapshot readback. Model: shell/common/snapshot_controller_impeller.cc
// DoMakeRasterSnapshot (DisplayListToTexture into a fresh render target) and
// lib/ui/painting/image_encoding_impeller.cc (blit the texture to a host
// buffer). Here the offscreen is an RGBA8 texture behind a temporary FBO that
// Impeller wraps, and the readback is glReadPixels on that FBO.
#include "scenegraph/GpuBackendGl.h"

#include <cstring>

#include "base/Trace.h"

#if !defined(__ANDROID__)
#define RNI_SNAPSHOT_GL 1
#include "scenegraph/SceneGraphGl.h"  // last: gl* are macros on Windows
#else
#define RNI_SNAPSHOT_GL 0
#endif

namespace rni {

#if RNI_SNAPSHOT_GL
namespace {

bool ReadbackGl(ImpellerContext ctx, ImpellerDisplayList dl, int w, int h,
                std::vector<uint8_t>* rgba) {
  TRACE_EVENT0("raster", "SnapshotReadback");
  if (ctx == nullptr || dl == nullptr || w <= 0 || h <= 0) return false;
  GLint prevFbo = 0;
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
  GLint prevViewport[4] = {0, 0, 0, 0};
  glGetIntegerv(GL_VIEWPORT, prevViewport);
  GLuint fbo = 0, color = 0, ds = 0;
  glGenTextures(1, &color);
  glBindTexture(GL_TEXTURE_2D, color);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color, 0);
  // Concave path fills are stencil-then-cover (same as the supersample offscreen).
  glGenRenderbuffers(1, &ds);
  glBindRenderbuffer(GL_RENDERBUFFER, ds);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, w, h);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, ds);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, ds);
  bool ok = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  if (ok) {
    // A view with no background is transparent in the capture, as in view-shot.
    glViewport(0, 0, w, h);
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
    ImpellerISize size = {w, h};
    ImpellerSurface surf =
        ImpellerSurfaceCreateWrappedFBONew(ctx, fbo, kImpellerPixelFormatRGBA8888, &size);
    ok = surf != nullptr && ImpellerSurfaceDrawDisplayList(surf, dl);
    if (surf) ImpellerSurfaceRelease(surf);
  }
  if (ok) {
    std::vector<uint8_t> raw((size_t)w * h * 4);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, raw.data());
    // glReadPixels' row 0 is the BOTTOM of the FBO; Impeller drew top-left.
    rgba->resize(raw.size());
    const size_t row = (size_t)w * 4;
    for (int y = 0; y < h; ++y) {
      std::memcpy(rgba->data() + (size_t)y * row, raw.data() + (size_t)(h - 1 - y) * row, row);
    }
  }
  glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prevFbo);
  glDeleteFramebuffers(1, &fbo);
  glDeleteRenderbuffers(1, &ds);
  glDeleteTextures(1, &color);
  glViewport(prevViewport[0], prevViewport[1], prevViewport[2], prevViewport[3]);
  return ok;
}

}  // namespace

SnapshotReadback MakeGlSnapshotReadback(ImpellerContext ctx) {
  return [ctx](ImpellerDisplayList dl, int w, int h, std::vector<uint8_t>* rgba) {
    return ReadbackGl(ctx, dl, w, h, rgba);
  };
}
#else
SnapshotReadback MakeGlSnapshotReadback(ImpellerContext) { return nullptr; }
#endif

}  // namespace rni
