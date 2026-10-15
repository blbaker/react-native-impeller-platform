#pragma once

// FP-25: the Android GLES fallback surface, the peer of AndroidVkSurface.
// ANativeWindow -> EGLSurface -> ImpellerContextCreateOpenGLESNew, and each
// frame wraps the window's default framebuffer (FBO 0) at the EGL surface's
// current size, like GlfwSurface on desktop.
// Model: shell/platform/android/android_context_gl_impeller.cc (onscreen config
// ES3, RGBA8888, depth 24, stencil 8, 4x MSAA; then ES2; then 1 sample) and
// android_surface_gl_impeller.cc (present = eglSwapBuffers).
// Threading: the EGL context is made current on the thread that calls Init and
// every later call must come from that thread (impeller.h: GL contexts are
// bound to the thread their context is current on).

#include <android/native_window.h>

#include "impeller.h"

namespace rni {

class AndroidGlSurface {
 public:
  AndroidGlSurface() = default;
  ~AndroidGlSurface();

  AndroidGlSurface(const AndroidGlSurface&) = delete;
  AndroidGlSurface& operator=(const AndroidGlSurface&) = delete;

  bool Init(ANativeWindow* window);
  // Destroys the EGLSurface only; the EGL + Impeller contexts survive a
  // surfaceDestroyed/surfaceCreated cycle, like AndroidVkSurface.
  void DetachWindow();
  bool AttachWindow(ANativeWindow* window);

  bool valid() const { return egl_surface_ != nullptr; }
  ImpellerContext context() const { return context_; }
  int width() const { return width_; }
  int height() const { return height_; }
  int gl_major() const { return gl_major_; }
  int samples() const { return samples_; }

  // Wraps FBO 0 at the surface's current size (read back with eglQuerySurface,
  // so a rotated window is followed with no resize callback). The caller
  // releases it through Present.
  ImpellerSurface AcquireNext();
  void Present(ImpellerSurface surface);

 private:
  bool EnsureContext();
  bool MakeCurrentWithoutWindow();

  void* display_{nullptr};  // EGLDisplay
  void* config_{nullptr};   // EGLConfig
  void* egl_context_{nullptr};
  void* egl_surface_{nullptr};
  void* pbuffer_{nullptr};  // keeps the context current while detached
  ANativeWindow* window_{nullptr};
  ImpellerContext context_{nullptr};
  int width_{0};
  int height_{0};
  int gl_major_{0};
  int samples_{0};
};

}  // namespace rni
