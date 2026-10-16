// FP-17: see IoContextEgl.h.
#include "host/IoContextEgl.h"

#include <cstdio>

#include "base/GlValidation.h"
#include "scenegraph/IoUploader.h"

#if !defined(_WIN32)
#include <EGL/egl.h>
#include <EGL/eglext.h>
#endif

namespace rni::ioegl {

#if defined(_WIN32)
bool StartFromCurrent() {
  std::printf("rn-impeller: io_context ok=0 share=0 reason=no-egl\n");
  return false;
}
void Stop() { io::Stop(); }
#else
namespace {
EGLDisplay gDpy = EGL_NO_DISPLAY;
EGLContext gCtx = EGL_NO_CONTEXT;
EGLSurface gPb = EGL_NO_SURFACE;

void* ProcAddr(const char* name, void*) { return (void*)eglGetProcAddress(name); }

bool Fail(const char* why) {
  std::printf("rn-impeller: io_context ok=0 share=0 reason=%s egl=0x%04x\n", why, eglGetError());
  if (gPb != EGL_NO_SURFACE) eglDestroySurface(gDpy, gPb);
  if (gCtx != EGL_NO_CONTEXT) eglDestroyContext(gDpy, gCtx);
  gPb = EGL_NO_SURFACE;
  gCtx = EGL_NO_CONTEXT;
  return false;
}
}  // namespace

bool StartFromCurrent() {
  if (!io::Enabled()) {
    std::printf("rn-impeller: io_context ok=0 share=0 reason=disabled\n");
    return false;
  }
  gDpy = eglGetCurrentDisplay();
  EGLContext share = eglGetCurrentContext();
  if (gDpy == EGL_NO_DISPLAY || share == EGL_NO_CONTEXT) return Fail("no-current-context");
  EGLint cfgId = 0, n = 0;
  EGLConfig cfg;
  if (!eglQueryContext(gDpy, share, EGL_CONFIG_ID, &cfgId)) return Fail("query-config");
  const EGLint cfgAttrs[] = {EGL_CONFIG_ID, cfgId, EGL_NONE};
  if (!eglChooseConfig(gDpy, cfgAttrs, &cfg, 1, &n) || n != 1) return Fail("choose-config");
  eglBindAPI(EGL_OPENGL_ES_API);
  // FP-05: the IO context is validated like the raster one.
  const EGLint dbg = rni::glvalidation::Enabled() ? 1 : 0;
  const EGLint ctxAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, 0x31B0 /*EGL_CONTEXT_OPENGL_DEBUG*/, dbg,
                             EGL_NONE};
  gCtx = eglCreateContext(gDpy, cfg, share, ctxAttrs);
  if (gCtx == EGL_NO_CONTEXT && eglGetError() == EGL_BAD_MATCH) {
    // FP-32: a share group's contexts must agree on the reset strategy, and a
    // context rebuilt after a loss is LOSE_CONTEXT_ON_RESET.
    const EGLint robustAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, 0x31B0 /*EGL_CONTEXT_OPENGL_DEBUG*/,
                                  dbg, EGL_CONTEXT_OPENGL_ROBUST_ACCESS_EXT, EGL_TRUE,
                                  EGL_CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY_EXT,
                                  EGL_LOSE_CONTEXT_ON_RESET_EXT, EGL_NONE};
    gCtx = eglCreateContext(gDpy, cfg, share, robustAttrs);
  }
  if (gCtx == EGL_NO_CONTEXT) return Fail("create-context");
  EGLint surfType = 0;
  eglGetConfigAttrib(gDpy, cfg, EGL_SURFACE_TYPE, &surfType);
  EGLDisplay dpy = gDpy;
  EGLContext ctx = gCtx;
  io::ContextHooks hooks;
  hooks.bind = [dpy, ctx, cfg, surfType] {
    eglBindAPI(EGL_OPENGL_ES_API);
    bool ok = eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);
    if (!ok && (surfType & EGL_PBUFFER_BIT)) {  // no surfaceless: a 1x1 pbuffer
      const EGLint pbAttrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
      gPb = eglCreatePbufferSurface(dpy, cfg, pbAttrs);
      ok = gPb != EGL_NO_SURFACE && eglMakeCurrent(dpy, gPb, gPb, ctx);
    }
    if (ok) rni::glvalidation::Install(&ProcAddr, nullptr);
    return ok;
  };
  hooks.unbind = [dpy] {
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglReleaseThread();
  };
  if (!io::Start(std::move(hooks))) return Fail("bind");
  std::printf("rn-impeller: io_context ok=1 share=1 reason=- pbuffer=%d\n",
              gPb != EGL_NO_SURFACE ? 1 : 0);
  return true;
}

void Stop() {
  io::Stop();
  if (gPb != EGL_NO_SURFACE) eglDestroySurface(gDpy, gPb);
  if (gCtx != EGL_NO_CONTEXT) eglDestroyContext(gDpy, gCtx);
  gPb = EGL_NO_SURFACE;
  gCtx = EGL_NO_CONTEXT;
}
#endif

}  // namespace rni::ioegl
