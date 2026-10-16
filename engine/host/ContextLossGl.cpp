#include "host/ContextLossGl.h"

#include <cstdio>
#include <string>

#include "base/GlValidation.h"

#if !defined(_WIN32)
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#endif

namespace rni::ctxlossgl {

#if defined(_WIN32)
bool Supported() { return false; }
bool Recreate(EglWindow&, std::string* why) {
  if (why) *why = "unsupported-platform";
  return false;
}
void Swap(const EglWindow&, bool* lost) { *lost = false; }
unsigned ResetStatus() { return 0; }
const char* ResetReason(unsigned) { return "none"; }
void ReportRobustness(const char*) {}
#else
namespace {
using ResetFn = GLenum (*)();
ResetFn LoadReset() {
  for (const char* n : {"glGetGraphicsResetStatus", "glGetGraphicsResetStatusKHR",
                        "glGetGraphicsResetStatusEXT"}) {
    if (auto f = (ResetFn)eglGetProcAddress(n)) return f;
  }
  return nullptr;
}

bool HasExt(EGLDisplay dpy, const char* name) {
  const char* s = eglQueryString(dpy, EGL_EXTENSIONS);
  if (s == nullptr) return false;
  const std::string all(s);
  const std::string want(name);
  for (size_t p = all.find(want); p != std::string::npos; p = all.find(want, p + 1)) {
    const size_t e = p + want.size();
    if ((p == 0 || all[p - 1] == ' ') && (e == all.size() || all[e] == ' ')) return true;
  }
  return false;
}

// What the current context was created with. GL has no portable query for it
// that does not raise GL_INVALID_ENUM below GL 4.5 / ES 3.2 (GL validation counts that).
bool gRobust = false;
}  // namespace

bool Supported() { return true; }

bool Recreate(EglWindow& w, std::string* why) {
  auto fail = [&](const char* m) {
    if (why) *why = m;
    return false;
  };
  EGLDisplay dpy = (EGLDisplay)w.display;
  EGLContext old = (EGLContext)w.context;
  EGLint cfgId = 0, clientType = EGL_OPENGL_ES_API, clientVersion = 0, n = 0;
  if (!eglQueryContext(dpy, old, EGL_CONFIG_ID, &cfgId)) return fail("query-config");
  eglQueryContext(dpy, old, EGL_CONTEXT_CLIENT_TYPE, &clientType);
  eglQueryContext(dpy, old, EGL_CONTEXT_CLIENT_VERSION, &clientVersion);
  const EGLint cfgAttrs[] = {EGL_CONFIG_ID, cfgId, EGL_NONE};
  EGLConfig cfg;
  if (!eglChooseConfig(dpy, cfgAttrs, &cfg, 1, &n) || n != 1) return fail("choose-config");
  // Rasterizer::Teardown: nothing stays current on the dead context.
  eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  eglDestroyContext(dpy, old);
  w.context = nullptr;
  if (!eglBindAPI((EGLenum)clientType)) return fail("bind-api");
  const EGLint dbg = rni::glvalidation::Enabled() ? 1 : 0;
  const bool es = clientType == EGL_OPENGL_ES_API;
  const EGLint major = es && clientVersion > 0 ? clientVersion : 0;
  EGLint eglMajor = 0, eglMinor = 0;
  eglInitialize(dpy, &eglMajor, &eglMinor);  // already initialised: returns the version
  const bool egl15 = eglMajor > 1 || (eglMajor == 1 && eglMinor >= 5);
  const bool robustExt = es && HasExt(dpy, "EGL_EXT_create_context_robustness");
  EGLContext ctx = EGL_NO_CONTEXT;
  bool robust = false;
  for (int attempt = 0; attempt < 2 && ctx == EGL_NO_CONTEXT; ++attempt) {
    EGLint a[16];
    int i = 0;
    if (major > 0) a[i++] = EGL_CONTEXT_MAJOR_VERSION, a[i++] = major;
    a[i++] = EGL_CONTEXT_OPENGL_DEBUG, a[i++] = dbg;
    robust = attempt == 0 && (robustExt || (!es && egl15));
    if (robust && robustExt) {  // EXT_create_context_robustness (GLES)
      a[i++] = EGL_CONTEXT_OPENGL_ROBUST_ACCESS_EXT, a[i++] = EGL_TRUE;
      a[i++] = EGL_CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY_EXT;
      a[i++] = EGL_LOSE_CONTEXT_ON_RESET_EXT;
    } else if (robust) {  // desktop GL on EGL 1.5
      a[i++] = EGL_CONTEXT_OPENGL_ROBUST_ACCESS, a[i++] = EGL_TRUE;
      a[i++] = EGL_CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY, a[i++] = EGL_LOSE_CONTEXT_ON_RESET;
    }
    a[i++] = EGL_NONE;
    ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, a);
  }
  if (ctx == EGL_NO_CONTEXT) return fail("create-context");
  EGLSurface surf = (EGLSurface)w.surface;
  if (!eglMakeCurrent(dpy, surf, surf, ctx)) {
    eglDestroyContext(dpy, ctx);
    return fail("make-current");
  }
  w.context = ctx;
  gRobust = robust;
  return true;
}

void Swap(const EglWindow& w, bool* lost) {
  *lost = false;
  if (eglSwapBuffers((EGLDisplay)w.display, (EGLSurface)w.surface) == EGL_TRUE) return;
  *lost = eglGetError() == EGL_CONTEXT_LOST;
}

unsigned ResetStatus() {
  // Only a LOSE_CONTEXT_ON_RESET context reports resets; never poll one that
  // was not created robust.
  static const ResetFn fn = LoadReset();
  if (fn == nullptr || !gRobust) return 0u;
  return (unsigned)fn();
}

const char* ResetReason(unsigned status) {
  switch (status) {
    case 0: return "none";
    case 0x8253: return "gl_reset_guilty";
    case 0x8254: return "gl_reset_innocent";
    case 0x8255: return "gl_reset_unknown";
    default: return "gl_reset_other";
  }
}

void ReportRobustness(const char* when) {
  std::printf("rn-impeller: context_robustness when=%s strategy=%s reset_fn=%d\n", when,
              gRobust ? "lose" : "none", LoadReset() != nullptr ? 1 : 0);
  std::fflush(stdout);
}
#endif

}  // namespace rni::ctxlossgl
