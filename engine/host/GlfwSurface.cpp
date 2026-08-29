#include "host/GlfwSurface.h"

#include <GLFW/glfw3.h>
#include <GLES3/gl3.h>

#include <cstdio>

namespace rni {

namespace {
void* ProcAddr(const char* name, void*) { return (void*)glfwGetProcAddress(name); }

void GlfwErrorCallback(int error, const char* description) {
  fprintf(stderr, "rn-impeller: GLFW error (%d): %s\n", error, description);
  fflush(stderr);
}
}  // namespace

GlfwSurface::~GlfwSurface() {
  if (typography_) ImpellerTypographyContextRelease(typography_);
  if (surface_) ImpellerSurfaceRelease(surface_);
  if (context_) ImpellerContextRelease(context_);
  if (window_) {
    glfwMakeContextCurrent(nullptr);
    glfwDestroyWindow(window_);
  }
  glfwTerminate();
}

bool GlfwSurface::init(int width, int height, std::string* error) {
  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };

  glfwSetErrorCallback(GlfwErrorCallback);
  if (!glfwInit()) return fail("glfwInit failed");

  // EGL context creation API, exactly as tools/window-spike.sh's
  // example_gl.c does — GLFW defaults to its native (GLX) API, and Impeller's
  // ProcAddressCallback here is glfwGetProcAddress, which only resolves GLES
  // symbols correctly when the context was created through EGL.
  glfwWindowHint(GLFW_CONTEXT_CREATION_API, GLFW_EGL_CONTEXT_API);

  window_ = glfwCreateWindow(width, height, "React Native (Impeller)", nullptr,
                             nullptr);
  if (!window_) return fail("glfwCreateWindow failed");

  int fbWidth = 0, fbHeight = 0;
  glfwGetFramebufferSize(window_, &fbWidth, &fbHeight);
  width_ = fbWidth;
  height_ = fbHeight;

  glfwMakeContextCurrent(window_);

  context_ = ImpellerContextCreateOpenGLESNew(IMPELLER_VERSION, &ProcAddr, nullptr);
  if (!context_) return fail("ImpellerContextCreateOpenGLESNew returned null");

  // fbo id 0 — the window's OWN default framebuffer, not one we allocate.
  // See the file comment: this is the one real difference from
  // HeadlessSurface, which must build its own texture+FBO because it has no
  // window to draw into.
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

void GlfwSurface::present() { glfwSwapBuffers(window_); }

}  // namespace rni
