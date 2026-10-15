#include "host/AndroidGlSurface.h"

#include "base/ContextFlags.h"

#include <EGL/egl.h>
#include <android/log.h>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "rn-impeller", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "rn-impeller", __VA_ARGS__)

#ifndef EGL_OPENGL_ES3_BIT
#define EGL_OPENGL_ES3_BIT 0x00000040
#endif

namespace rni {
namespace {

void* GlProcAddress(const char* name, void* /*user_data*/) {
  return reinterpret_cast<void*>(eglGetProcAddress(name));
}

EGLDisplay Dpy(void* d) { return static_cast<EGLDisplay>(d); }

}  // namespace

AndroidGlSurface::~AndroidGlSurface() {
  DetachWindow();
  if (display_ == nullptr) return;
  if (context_ != nullptr) {
    // Impeller frees GL objects on release: keep a context current for it.
    MakeCurrentWithoutWindow();
    ImpellerContextRelease(context_);
    context_ = nullptr;
  }
  eglMakeCurrent(Dpy(display_), EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  if (pbuffer_ != nullptr) eglDestroySurface(Dpy(display_), pbuffer_);
  if (egl_context_ != nullptr) eglDestroyContext(Dpy(display_), egl_context_);
  eglTerminate(Dpy(display_));
  display_ = nullptr;
}

bool AndroidGlSurface::EnsureContext() {
  if (egl_context_ != nullptr) return true;
  EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, nullptr, nullptr)) {
    LOGE("gles: eglGetDisplay/eglInitialize failed 0x%x", eglGetError());
    return false;
  }
  display_ = dpy;
  // Flutter's onscreen chain: ES3 4x -> ES2 4x -> single sample.
  struct Try { EGLint api_bit; int major; EGLint samples; };
  constexpr Try kTries[] = {{EGL_OPENGL_ES3_BIT, 3, 4}, {EGL_OPENGL_ES2_BIT, 2, 4},
                            {EGL_OPENGL_ES3_BIT, 3, 0}, {EGL_OPENGL_ES2_BIT, 2, 0}};
  EGLConfig cfg = nullptr;
  for (const Try& t : kTries) {
    const EGLint attrs[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                            EGL_RENDERABLE_TYPE, t.api_bit,
                            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
                            EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
                            EGL_SAMPLE_BUFFERS, t.samples > 0 ? 1 : 0,
                            EGL_SAMPLES, t.samples, EGL_NONE};
    EGLint n = 0;
    if (eglChooseConfig(dpy, attrs, &cfg, 1, &n) && n == 1) {
      gl_major_ = t.major;
      samples_ = t.samples > 0 ? t.samples : 1;
      break;
    }
    cfg = nullptr;
  }
  if (cfg == nullptr) {
    LOGE("gles: no RGBA8888 d24s8 window config");
    return false;
  }
  config_ = cfg;
  eglBindAPI(EGL_OPENGL_ES_API);
  const EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, gl_major_, EGL_NONE};
  EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
  if (ctx == EGL_NO_CONTEXT) {
    LOGE("gles: eglCreateContext ES%d failed 0x%x", gl_major_, eglGetError());
    return false;
  }
  egl_context_ = ctx;
  if (!MakeCurrentWithoutWindow()) {
    LOGE("gles: no surfaceless or pbuffer make-current 0x%x", eglGetError());
    return false;
  }
  rni::contextflags::ApplyBeforeCreate();  // FP-22
  context_ = ImpellerContextCreateOpenGLESNew(IMPELLER_VERSION, GlProcAddress, nullptr);
  rni::contextflags::Report(context_);
  if (context_ == nullptr) {
    LOGE("gles: ImpellerContextCreateOpenGLESNew failed");
    return false;
  }
  LOGI("Impeller GLES context created: ES%d samples=%d", gl_major_, samples_);
  return true;
}

// Keeps the context current while no window is attached (surfaceDestroyed),
// so Impeller's context outlives the window: EGL_KHR_surfaceless_context,
// else a 1x1 pbuffer (MSAA window configs often lack EGL_PBUFFER_BIT).
bool AndroidGlSurface::MakeCurrentWithoutWindow() {
  EGLDisplay dpy = Dpy(display_);
  if (pbuffer_ == nullptr &&
      eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, egl_context_)) {
    return true;
  }
  if (pbuffer_ == nullptr) {
    const EGLint pb_attrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    EGLSurface pb = eglCreatePbufferSurface(dpy, config_, pb_attrs);
    if (pb == EGL_NO_SURFACE) return false;
    pbuffer_ = pb;
  }
  return eglMakeCurrent(dpy, pbuffer_, pbuffer_, egl_context_) == EGL_TRUE;
}

bool AndroidGlSurface::Init(ANativeWindow* window) {
  if (!EnsureContext()) return false;
  return AttachWindow(window);
}

bool AndroidGlSurface::AttachWindow(ANativeWindow* window) {
  if (window == nullptr || !EnsureContext()) return false;
  DetachWindow();
  ANativeWindow_acquire(window);
  window_ = window;
  EGLSurface s = eglCreateWindowSurface(Dpy(display_), config_, window, nullptr);
  if (s == EGL_NO_SURFACE ||
      !eglMakeCurrent(Dpy(display_), s, s, egl_context_)) {
    LOGE("gles: window surface failed 0x%x", eglGetError());
    if (s != EGL_NO_SURFACE) eglDestroySurface(Dpy(display_), s);
    DetachWindow();
    return false;
  }
  egl_surface_ = s;
  width_ = ANativeWindow_getWidth(window);
  height_ = ANativeWindow_getHeight(window);
  LOGI("Android GLES surface ready: %dx%d", width_, height_);
  return true;
}

void AndroidGlSurface::DetachWindow() {
  if (egl_surface_ != nullptr) {
    MakeCurrentWithoutWindow();
    eglDestroySurface(Dpy(display_), egl_surface_);
    egl_surface_ = nullptr;
  }
  if (window_ != nullptr) {
    ANativeWindow_release(window_);
    window_ = nullptr;
  }
  width_ = 0;
  height_ = 0;
}

ImpellerSurface AndroidGlSurface::AcquireNext() {
  if (egl_surface_ == nullptr || context_ == nullptr) return nullptr;
  EGLint w = 0, h = 0;
  eglQuerySurface(Dpy(display_), egl_surface_, EGL_WIDTH, &w);
  eglQuerySurface(Dpy(display_), egl_surface_, EGL_HEIGHT, &h);
  if (w <= 0 || h <= 0) return nullptr;
  width_ = w;
  height_ = h;
  const ImpellerISize size = {w, h};
  return ImpellerSurfaceCreateWrappedFBONew(context_, 0,
                                            kImpellerPixelFormatRGBA8888, &size);
}

void AndroidGlSurface::Present(ImpellerSurface surface) {
  if (surface == nullptr) return;
  ImpellerSurfaceRelease(surface);
  if (!eglSwapBuffers(Dpy(display_), egl_surface_)) {
    LOGE("gles: eglSwapBuffers failed 0x%x", eglGetError());
  }
}

}  // namespace rni
