#include "host/GlfwSurface.h"

#include <GLFW/glfw3.h>
#include <GLES3/gl3.h>

#if defined(__APPLE__)
// ⛔ macOS REACHES THE WINDOW THROUGH ANGLE, NOT THROUGH SYSTEM EGL.
// Same reason HeadlessSurface has an APPLE branch: Apple ships a frozen
// desktop GL 2.1 compatibility profile and NO EGL and NO GLES at all. The
// EGL_PLATFORM_ANGLE_* tokens live only in ANGLE's own extension header, which
// is vendored beside the Khronos ones (engine/third_party/khronos).
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#endif

#include <cstdio>

namespace rni {

#if defined(__APPLE__)
// Defined in GlfwCocoaView.mm — returns the NSWindow's contentView with
// wantsLayer set, which is what ANGLE/Metal accepts as a native window.
void* GlfwCocoaLayerBackedView(GLFWwindow* window);
#endif

namespace {
#if defined(__APPLE__)
// ⛔ eglGetProcAddress, NOT glfwGetProcAddress, ON DARWIN.
// GLFW created the window with GLFW_NO_API here, so it owns no GL context and
// its loader resolves nothing. Impeller would get a table of null pointers and
// fail somewhere far away from the cause.
void* ProcAddr(const char* name, void*) { return (void*)eglGetProcAddress(name); }
#else
void* ProcAddr(const char* name, void*) { return (void*)glfwGetProcAddress(name); }
#endif

void GlfwErrorCallback(int error, const char* description) {
  fprintf(stderr, "rn-impeller: GLFW error (%d): %s\n", error, description);
  fflush(stderr);
}
}  // namespace

GlfwSurface::~GlfwSurface() {
  if (typography_) ImpellerTypographyContextRelease(typography_);
  if (surface_) ImpellerSurfaceRelease(surface_);
  if (context_) ImpellerContextRelease(context_);
#if defined(__APPLE__)
  if (display_ != EGL_NO_DISPLAY) {
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (eglSurface_ != EGL_NO_SURFACE) eglDestroySurface(display_, eglSurface_);
    if (eglContext_ != EGL_NO_CONTEXT) eglDestroyContext(display_, eglContext_);
    eglTerminate(display_);
  }
  if (window_) glfwDestroyWindow(window_);
#else
  if (window_) {
    glfwMakeContextCurrent(nullptr);
    glfwDestroyWindow(window_);
  }
#endif
  glfwTerminate();
}

#if defined(__APPLE__)
bool GlfwSurface::initAngleForWindow(std::string* error) {
  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };

  auto getPlatformDisplay =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
  if (!getPlatformDisplay) return fail("eglGetPlatformDisplayEXT unavailable");

  // Identical acquisition to HeadlessSurface::init — including PRINTING the
  // backend that actually took, never inferring it. A silent fallback from
  // METAL to DEFAULT renders correctly and identically, which is exactly how a
  // platform gets declared working on a path it never took.
  //
  // The cast: eglplatform.h makes EGLNativeDisplayType a plain `int` on Apple,
  // so reinterpret_cast is the one spelling valid for both integer and pointer
  // sources. See the long note in HeadlessSurface.cpp.
  struct Attempt { const char* name; EGLint type; };
  const Attempt attempts[] = {
      {"METAL", EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE},
      {"DEFAULT", EGL_PLATFORM_ANGLE_TYPE_DEFAULT_ANGLE},
  };
  for (const auto& a : attempts) {
    const EGLint dpyAttrs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, a.type, EGL_NONE};
    EGLDisplay d = getPlatformDisplay(
        EGL_PLATFORM_ANGLE_ANGLE,
        reinterpret_cast<void*>(EGL_DEFAULT_DISPLAY), dpyAttrs);
    if (d == EGL_NO_DISPLAY) continue;
    EGLint maj = 0, min = 0;
    if (!eglInitialize(d, &maj, &min)) continue;
    display_ = d;
    fprintf(stderr, "rn-impeller: ANGLE backend=%s (windowed)\n", a.name);
    break;
  }
  if (display_ == EGL_NO_DISPLAY) return fail("no ANGLE display could be initialised");

  // ⛔ EGL_WINDOW_BIT, NOT EGL_PBUFFER_BIT. This is the only substantive
  // difference from the headless config: a pbuffer config will be returned
  // happily by eglChooseConfig and then rejected by eglCreateWindowSurface.
  const EGLint cfgAttrs[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                             EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                             EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                             EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg;
  EGLint n = 0;
  if (!eglChooseConfig(display_, cfgAttrs, &cfg, 1, &n) || n != 1) {
    return fail("eglChooseConfig (window) failed");
  }
  if (!eglBindAPI(EGL_OPENGL_ES_API)) return fail("eglBindAPI failed");

  void* view = GlfwCocoaLayerBackedView(window_);
  if (!view) return fail("glfwGetCocoaWindow/contentView returned null");

  eglSurface_ = eglCreateWindowSurface(display_, cfg,
                                       (EGLNativeWindowType)view, nullptr);
  if (eglSurface_ == EGL_NO_SURFACE) return fail("eglCreateWindowSurface failed");

  const EGLint ctxAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
  eglContext_ = eglCreateContext(display_, cfg, EGL_NO_CONTEXT, ctxAttrs);
  if (eglContext_ == EGL_NO_CONTEXT) return fail("eglCreateContext failed");
  if (!eglMakeCurrent(display_, eglSurface_, eglSurface_, eglContext_)) {
    return fail("eglMakeCurrent (window) failed");
  }
  return true;
}
#endif

bool GlfwSurface::init(int width, int height, std::string* error) {
  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };

  glfwSetErrorCallback(GlfwErrorCallback);
  if (!glfwInit()) return fail("glfwInit failed");

#if defined(__APPLE__)
  // ⛔ GLFW MUST NOT TRY TO MAKE A CONTEXT ON DARWIN.
  // The Linux hint below (GLFW_EGL_CONTEXT_API) asks GLFW for a SYSTEM EGL.
  // macOS has none, so GLFW refuses the window outright with
  // "EGL: Failed to find support for OpenGL" and glfwCreateWindow returns null
  // — before any of our code runs, which makes it read like an ANGLE problem
  // when ANGLE has not been consulted yet.
  //
  // GLFW_NO_API means GLFW owns the window and its event loop ONLY; we build
  // the ANGLE display/context ourselves and attach it to the view's CALayer,
  // exactly as HeadlessSurface builds its offscreen one.
  glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
#else
  // EGL context creation API, exactly as tools/window-spike.sh's
  // example_gl.c does — GLFW defaults to its native (GLX) API, and Impeller's
  // ProcAddressCallback here is glfwGetProcAddress, which only resolves GLES
  // symbols correctly when the context was created through EGL.
  glfwWindowHint(GLFW_CONTEXT_CREATION_API, GLFW_EGL_CONTEXT_API);
#endif

  window_ = glfwCreateWindow(width, height, "React Native (Impeller)", nullptr,
                             nullptr);
  if (!window_) return fail("glfwCreateWindow failed");

  int fbWidth = 0, fbHeight = 0;
  glfwGetFramebufferSize(window_, &fbWidth, &fbHeight);
  width_ = fbWidth;
  height_ = fbHeight;

#if defined(__APPLE__)
  if (!initAngleForWindow(error)) return false;
#else
  glfwMakeContextCurrent(window_);
#endif

  context_ = ImpellerContextCreateOpenGLESNew(IMPELLER_VERSION, &ProcAddr, nullptr);
  if (!context_) return fail("ImpellerContextCreateOpenGLESNew returned null");

  // fbo id 0 — the window's OWN default framebuffer, not one we allocate.
  // See the file comment: this is the one real difference from
  // HeadlessSurface, which must build its own texture+FBO because it has no
  // window to draw into. True on darwin too: ANGLE's window surface presents
  // through framebuffer 0 just as a GLX/EGL window surface does.
  ImpellerISize size = {width_, height_};
  surface_ = ImpellerSurfaceCreateWrappedFBONew(
      context_, 0u, kImpellerPixelFormatRGBA8888, &size);
  if (!surface_) return fail("ImpellerSurfaceCreateWrappedFBONew returned null");

  typography_ = ImpellerTypographyContextNew();
  if (!typography_) return fail("ImpellerTypographyContextNew returned null");

  std::printf("rn-impeller: GL_RENDERER=%s\n", (const char*)glGetString(GL_RENDERER));
  std::fflush(stdout);
  return true;
}

bool GlfwSurface::drawDisplayList(ImpellerDisplayList dl) {
  if (!ImpellerSurfaceDrawDisplayList(surface_, dl)) return false;
  glFinish();
  return true;
}

bool GlfwSurface::readPixels(std::vector<Px>* out) {
  std::vector<Px> raw((size_t)width_ * height_);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glReadPixels(0, 0, width_, height_, GL_RGBA, GL_UNSIGNED_BYTE, raw.data());
  if (glGetError() != GL_NO_ERROR) return false;
  out->resize(raw.size());
  // Same Y-flip as HeadlessSurface::readPixels — glReadPixels' origin is
  // bottom-left, Impeller draws top-left.
  for (int y = 0; y < height_; ++y) {
    for (int x = 0; x < width_; ++x) {
      (*out)[(size_t)y * width_ + x] = raw[(size_t)(height_ - 1 - y) * width_ + x];
    }
  }
  return true;
}

void GlfwSurface::pollEvents() { glfwPollEvents(); }

bool GlfwSurface::shouldClose() const {
  return window_ ? glfwWindowShouldClose(window_) : true;
}

void GlfwSurface::present() {
#if defined(__APPLE__)
  // glfwSwapBuffers is a NO-OP for a GLFW_NO_API window — GLFW has no context
  // to swap. The swap belongs to the EGL surface we created.
  eglSwapBuffers(display_, eglSurface_);
#else
  glfwSwapBuffers(window_);
#endif
}

}  // namespace rni
