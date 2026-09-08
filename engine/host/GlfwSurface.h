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

#include <atomic>
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

  // ⛔ SCALE IS DETECTED ONCE AT init(). THIS IS HOW IT STOPS BEING ONCE.
  // Until now nothing in this class observed the window after creation:
  // glfwSetFramebufferSizeCallback was absent from the whole tree (measured
  // 2026-09-04). That makes the Retina fix correct at startup and wrong after
  // the first resize or the first drag to a monitor with a different backing
  // scale, which is the case no startup screenshot can catch because every
  // startup screenshot is taken before it. RN does not stop at detection
  // either: iOS listens on didUpdateDimensions, Android on configuration
  // change.
  //
  // The callback runs on the event thread inside glfwPollEvents, so it does
  // the cheap part (re-read both sizes, raise a flag) and nothing else. The
  // frame loop calls consumeDirty() and owns the expensive part: reallocating
  // the Impeller surface and re-driving the layout. Doing GL work from the
  // callback would race the paint that is already in flight.
  bool consumeDirty();

  // Drives a resize from inside the process, for gates. Produces the SAME
  // framebuffer-size callback a user drag produces; it is the identical code
  // path entered from a different caller. There is no headless way to make a
  // window manager resize a window, so without this the feature is only
  // testable by a human with a mouse, which is not a gate.
  void requestSize(int pointW, int pointH);

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
  // Written by the GLFW callback on the event thread, read and cleared by the
  // frame loop. std::atomic rather than a plain bool because those are two
  // different threads and a torn read here shows up as a resize that is
  // silently dropped once in a while, which is far worse to debug than one
  // that never works.
  std::atomic<bool> dirty_{false};
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
