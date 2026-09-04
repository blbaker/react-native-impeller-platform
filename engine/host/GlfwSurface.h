// GlfwSurface — a REAL on-screen window: GLFW (X11/EGL) + Impeller wrapping
// the window's default framebuffer.
//
// Peer of HeadlessSurface, same contract (init / context / surface /
// typography / width / height / drawDisplayList / readPixels), plus the
// window-lifecycle calls HeadlessSurface has no use for: pollEvents(),
// shouldClose(), present(). Built from tools/window-spike.sh, which proved
// the whole chain (GLFW -> X11/Xwayland -> EGL/GLES -> Impeller GL context ->
// ImpellerSurfaceCreateWrappedFBONew -> glfwSwapBuffers) works on this host.
//
// ⛔ THE FBO IS 0, NOT AN OFFSCREEN ONE. HeadlessSurface allocates its own
// texture+FBO because there is no window to draw into; here GLFW's own
// context already has a window-system-provided default framebuffer, and that
// IS what ImpellerSurfaceCreateWrappedFBONew wraps (see example_gl.c:55-56 —
// fbo id 0u). readPixels() therefore binds framebuffer 0, not a private one.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "host/Pixel.h"
#include "impeller.h"

#if defined(__APPLE__)
// macOS has no system EGL; the windowed path builds an ANGLE display/context
// itself and attaches it to the Cocoa view's layer. Those handles have to live
// for the surface's lifetime, so they are members here. See GlfwSurface.cpp.
#include <EGL/egl.h>
#endif

struct GLFWwindow;

namespace rni {

class GlfwSurface {
 public:
  ~GlfwSurface();

  // Returns false and fills `error` rather than aborting, matching
  // HeadlessSurface's contract.
  bool init(int width, int height, std::string* error);

  ImpellerContext context() const { return context_; }
  ImpellerSurface surface() const { return surface_; }
  ImpellerTypographyContext typography() const { return typography_; }
  int width() const { return width_; }
  int height() const { return height_; }

  // ⛔ width()/height() ARE PIXELS; THESE ARE POINTS.
  // glfwCreateWindow takes screen coordinates (points) and
  // glfwGetFramebufferSize reports pixels; on a Retina display the second is
  // twice the first. Both are recorded at init so the host can derive the
  // backing scale instead of assuming 1.0 — see host/PointScale.h.
  int pointWidth() const { return pointWidth_; }
  int pointHeight() const { return pointHeight_; }

  bool drawDisplayList(ImpellerDisplayList dl);

  // Reads the DEFAULT framebuffer back, already Y-flipped into top-left
  // order (same convention as HeadlessSurface::readPixels) so a screenshot
  // gate can treat both surfaces identically.
  bool readPixels(std::vector<Px>* out);

  static bool writePpm(const std::string& path, const std::vector<Px>& px,
                       int width, int height) {
    return WritePpm(path, px, width, height);
  }

  // Window-lifecycle calls HeadlessSurface has no analogue for.
  void pollEvents();
  bool shouldClose() const;
  void present();  // glfwSwapBuffers

 private:
#if defined(__APPLE__)
  // Builds the ANGLE display/context and the window surface bound to the
  // Cocoa view. Split out because it is the entire darwin-only story.
  bool initAngleForWindow(std::string* error);
#endif

  int width_{0};
  int height_{0};
  int pointWidth_{0};
  int pointHeight_{0};
  GLFWwindow* window_{nullptr};
#if defined(__APPLE__)
  EGLDisplay display_{EGL_NO_DISPLAY};
  EGLSurface eglSurface_{EGL_NO_SURFACE};
  EGLContext eglContext_{EGL_NO_CONTEXT};
#endif
  ImpellerContext context_{nullptr};
  ImpellerSurface surface_{nullptr};
  ImpellerTypographyContext typography_{nullptr};
};

}  // namespace rni
