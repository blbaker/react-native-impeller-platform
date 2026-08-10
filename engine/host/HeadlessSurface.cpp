#include "host/HeadlessSurface.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
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
  EGLDisplay dpy = getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                                      EGL_DEFAULT_DISPLAY, nullptr);
  if (dpy == EGL_NO_DISPLAY) return fail("surfaceless eglGetPlatformDisplay failed");
  EGLint major = 0, minor = 0;
  if (!eglInitialize(dpy, &major, &minor)) return fail("eglInitialize failed");
  display_ = dpy;

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

bool HeadlessSurface::writePpm(const std::string& path,
                               const std::vector<Px>& px, int width,
                               int height) {
  FILE* f = fopen(path.c_str(), "wb");
  if (!f) return false;
  fprintf(f, "P6\n%d %d\n255\n", width, height);
  for (const auto& p : px) fwrite(&p, 1, 3, f);
  fclose(f);
  return true;
}

}  // namespace rni
