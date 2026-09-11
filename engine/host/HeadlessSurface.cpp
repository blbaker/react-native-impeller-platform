#include "host/HeadlessSurface.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#if defined(__APPLE__)
// EGL_PLATFORM_ANGLE_* live ONLY in ANGLE's own extension header, not in the
// Khronos eglext.h (grep: 0 hits there, 3 here). Vendored alongside the other
// Khronos headers. Windows includes it via WinGLSurface for the same reason.
#include <EGL/eglext_angle.h>
#endif
#include <GLES3/gl3.h>

#include <cstdio>

namespace rni {

namespace {
void* ProcAddr(const char* name, void*) { return (void*)eglGetProcAddress(name); }
}  // namespace

HeadlessSurface::~HeadlessSurface() {
  if (typography_) ImpellerTypographyContextRelease(typography_);
  if (surface_) ImpellerSurfaceRelease(surface_);
  if (context_) ImpellerContextRelease(context_);
}

bool HeadlessSurface::init(int width, int height, std::string* error) {
  width_ = width;
  height_ = height;

  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };

  // Plain eglGetDisplay(EGL_DEFAULT_DISPLAY) FAILS with no display server;
  // the surfaceless platform extension is the whole trick.
  auto getPlatformDisplay =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
  if (!getPlatformDisplay) return fail("eglGetPlatformDisplayEXT unavailable");
  // ⛔ THE DISPLAY PATH IS PER-PLATFORM, AND SO IS THE CAST.
  //
  // Linux/Mesa: EGL_PLATFORM_SURFACELESS_MESA is the whole trick — it yields a
  // display with no display server at all.
  //
  // macOS: that enum is a MESA extension and ANGLE does not implement it. The
  // same job is done by EGL_PLATFORM_ANGLE_ANGLE with a backend type, exactly
  // as WinGLSurface does for D3D11 — here METAL, then ANGLE's own default.
  // The chosen backend is PRINTED, never inferred: a silent fallback renders
  // correctly and identically, which is precisely how a platform gets declared
  // working on a path it never actually took.
  //
  // ⚠️ AND EGL_DEFAULT_DISPLAY IS NOT THE SAME TYPE EVERYWHERE. eglplatform.h
  // makes EGLNativeDisplayType a POINTER on Linux/Windows but a plain `int` on
  // Apple, so passing EGL_DEFAULT_DISPLAY straight into the void* parameter is
  // a hard compile error on macOS only.
  //
  // ⛔ ONE reinterpret_cast, NOT static_cast — and the Linux build is what
  // proved it. A first attempt used static_cast<intptr_t> to widen Apple's int,
  // which is exactly right on Apple and ILLEGAL on Linux, where the operand is
  // already a void* ("invalid static_cast from void* to intptr_t"). A cast
  // written for the new platform must still compile on the old one;
  // reinterpret_cast is the one spelling valid for both an integer and a
  // pointer source, so this stays a single code path.
  EGLDisplay dpy = EGL_NO_DISPLAY;
  auto nativeDefaultDisplay = []() -> void* {
    return reinterpret_cast<void*>(EGL_DEFAULT_DISPLAY);
  };

#if defined(__APPLE__)
  struct Attempt { const char* name; EGLint type; };
  const Attempt attempts[] = {
      {"METAL", EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE},
      {"DEFAULT", EGL_PLATFORM_ANGLE_TYPE_DEFAULT_ANGLE},
  };
  for (const auto& a : attempts) {
    const EGLint dpyAttrs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, a.type, EGL_NONE};
    EGLDisplay d = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE,
                                      nativeDefaultDisplay(), dpyAttrs);
    if (d == EGL_NO_DISPLAY) continue;
    EGLint maj = 0, min = 0;
    if (!eglInitialize(d, &maj, &min)) continue;
    dpy = d;
    fprintf(stderr, "rn-impeller: ANGLE backend=%s\n", a.name);
    break;
  }
  if (dpy == EGL_NO_DISPLAY) return fail("no ANGLE display could be initialised");
  display_ = dpy;
#else
  dpy = getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                           nativeDefaultDisplay(), nullptr);
  if (dpy == EGL_NO_DISPLAY) return fail("surfaceless eglGetPlatformDisplay failed");
  EGLint major = 0, minor = 0;
  if (!eglInitialize(dpy, &major, &minor)) return fail("eglInitialize failed");
  display_ = dpy;
#endif

  const EGLint cfgAttrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                             EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                             EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                             EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg;
  EGLint n = 0;
  if (!eglChooseConfig(dpy, cfgAttrs, &cfg, 1, &n) || n != 1) {
    return fail("eglChooseConfig failed");
  }
  if (!eglBindAPI(EGL_OPENGL_ES_API)) return fail("eglBindAPI failed");
  const EGLint ctxAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
  EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxAttrs);
  if (ctx == EGL_NO_CONTEXT) return fail("eglCreateContext failed");
  if (!eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
    return fail("eglMakeCurrent (surfaceless) failed");
  }
  eglContext_ = ctx;

  glGenTextures(1, &texture_);
  glBindTexture(GL_TEXTURE_2D, texture_);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width_, height_, 0, GL_RGBA,
               GL_UNSIGNED_BYTE, nullptr);
  glGenFramebuffers(1, &fbo_);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         texture_, 0);

  // ⛔ A COLOUR-ONLY FBO SILENTLY BREAKS EVERY CONCAVE FILL.
  //
  // Impeller fills a path one of two ways. A CONVEX path is tessellated
  // directly and needs no auxiliary buffer. A NON-CONVEX path goes through
  // stencil-then-cover: the coverage is accumulated into the STENCIL buffer,
  // then a cover geometry — the path's BOUNDING BOX — is drawn masked by it.
  //
  // With no stencil attachment the accumulate pass is a no-op and the cover
  // pass is unmasked, so the shape paints AS ITS BOUNDING BOX. That is not a
  // crash, not a GL error, and not a log line: convex shapes stay pixel-exact,
  // so squares, diamonds, circles and every STROKE (stroking tessellates its
  // own convex quads) all look perfect. Only filled concave geometry is wrong.
  //
  // Measured 2026-09-11 against a 5-case probe at 700x300 (tools/ci-concave.sh):
  //   square 6400/6400 and diamond 3200/3200 exact, while the L, the arrowhead
  //   and the notched diamond each painted 6400 — their 80x80 box — instead of
  //   4800, 4800 and 3000. A diamond with one vertex pushed 0.001 units inward
  //   becomes non-convex and jumps from 3200 to the full 6400.
  //
  // GL_DEPTH24_STENCIL8 rather than a stencil-only renderbuffer: Impeller's GLES
  // backend also uses depth for its clip/coverage bookkeeping, and packed
  // depth-stencil is the combination guaranteed renderable in core GLES3.
  glGenRenderbuffers(1, &depthStencil_);
  glBindRenderbuffer(GL_RENDERBUFFER, depthStencil_);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, width_, height_);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                            GL_RENDERBUFFER, depthStencil_);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT,
                            GL_RENDERBUFFER, depthStencil_);

  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
    return fail("FBO incomplete");
  }

  // A version mismatch returns null by design rather than misbehaving.
  context_ = ImpellerContextCreateOpenGLESNew(IMPELLER_VERSION, &ProcAddr, nullptr);
  if (!context_) return fail("ImpellerContextCreateOpenGLESNew returned null");
  ImpellerISize size = {width_, height_};
  surface_ = ImpellerSurfaceCreateWrappedFBONew(
      context_, fbo_, kImpellerPixelFormatRGBA8888, &size);
  if (!surface_) return fail("ImpellerSurfaceCreateWrappedFBONew returned null");

  typography_ = ImpellerTypographyContextNew();
  if (!typography_) return fail("ImpellerTypographyContextNew returned null");

  std::printf("rn-impeller: GL_RENDERER=%s\n", (const char*)glGetString(GL_RENDERER));
  std::fflush(stdout);
  return true;
}

bool HeadlessSurface::drawDisplayList(ImpellerDisplayList dl) {
  if (!ImpellerSurfaceDrawDisplayList(surface_, dl)) return false;
  glFinish();
  return true;
}

bool HeadlessSurface::readPixels(std::vector<Px>* out) {
  std::vector<Px> raw((size_t)width_ * height_);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
  glReadPixels(0, 0, width_, height_, GL_RGBA, GL_UNSIGNED_BYTE, raw.data());
  if (glGetError() != GL_NO_ERROR) return false;
  out->resize(raw.size());
  for (int y = 0; y < height_; ++y) {
    for (int x = 0; x < width_; ++x) {
      (*out)[(size_t)y * width_ + x] = raw[(size_t)(height_ - 1 - y) * width_ + x];
    }
  }
  return true;
}

}  // namespace rni
