// FP-32: GlfwSurface's half of context-loss recovery (host/ContextLoss.h).
// Model: shell/common/rasterizer.cc Teardown (surface + context released on
// the raster thread) then Setup on a new surface, with shell.cc's order: the
// IO manager's resource context goes with the old share group and a new one is
// made from the new context (Shell::OnPlatformViewCreated io_task).
#include "base/ContextFlags.h"
#include "base/GlLimits.h"
#include "base/GlValidation.h"
#include "fabric/ImageStore.h"
#include "host/GlfwSurface.h"
#include "host/IoContextEgl.h"
#include "host/RecordNoGl.h"
#include "text/TypographyContexts.h"

#if defined(_WIN32)
#define GLFW_INCLUDE_NONE
#endif
#include <GLFW/glfw3.h>
#if !defined(_WIN32) && !defined(__APPLE__)
#define GLFW_EXPOSE_NATIVE_EGL
#include <GLFW/glfw3native.h>
#endif
#if !defined(_WIN32)
#include <GLES3/gl3.h>
#endif

#include <cstdio>

namespace rni {
namespace {
#if defined(__APPLE__)
void* ProcAddr(const char* name, void*) { return (void*)eglGetProcAddress(name); }
#elif !defined(_WIN32)
void* ProcAddr(const char* name, void*) { return (void*)glfwGetProcAddress(name); }
#endif
}  // namespace

void GlfwSurface::captureEglWindow() {
#if defined(__APPLE__)
  egl_ = {display_, eglSurface_, eglContext_};
#elif !defined(_WIN32)
  egl_ = {glfwGetEGLDisplay(), glfwGetEGLSurface(window_), glfwGetEGLContext(window_)};
  if (egl_.display == EGL_NO_DISPLAY || egl_.surface == EGL_NO_SURFACE) egl_ = {};
#endif
  rni::ctxlossgl::ReportRobustness("init");
}

unsigned GlfwSurface::pollResetStatus() const {
  return egl_.display != nullptr ? rni::ctxlossgl::ResetStatus() : 0u;
}

bool GlfwSurface::rebuildGpu(bool rasterThread, std::string* error) {
  auto fail = [&](const std::string& msg) {
    if (error) *error = msg;
    return false;
  };
#if defined(_WIN32)
  (void)rasterThread;
  return fail("unsupported");  // GL goes through the ANGLE loader table there
#else
#if defined(__APPLE__)
  if (metal_) return fail("metal");
#endif
  if (!rni::ctxlossgl::Supported() || egl_.display == nullptr) return fail("unsupported");
  // Teardown, newest first: the IO context shares the dying group, then the
  // Impeller objects (released while their context is still current, so the
  // reactor can still free what it owns), then the EGL context itself.
  rni::ioegl::Stop();
  rni::recordgl::SetContextHooks({});
  if (surface_) ImpellerSurfaceRelease(surface_);
  surface_ = nullptr;
  if (context_) ImpellerContextRelease(context_);
  context_ = nullptr;
  std::string why;
  if (!rni::ctxlossgl::Recreate(egl_, &why)) return fail("egl-" + why);
  rebuilt_ = true;
#if defined(__APPLE__)
  eglContext_ = (EGLContext)egl_.context;  // ~GlfwSurface destroys it
#endif
  // Setup: the same steps initGpu takes on a fresh context.
  rni::glvalidation::Install(&ProcAddr, nullptr);
  rni::image::SetMaxTextureSize(rni::gllimits::MaxTextureSize(&ProcAddr, nullptr));
  rni::contextflags::ApplyBeforeCreate();
  context_ = ImpellerContextCreateOpenGLESNew(IMPELLER_VERSION, &ProcAddr, nullptr);
  rni::contextflags::Report(context_);
  if (!context_) return fail("impeller-context");
  glViewport(0, 0, gpuWidth_, gpuHeight_);
  ImpellerISize size = {gpuWidth_, gpuHeight_};
  surface_ = ImpellerSurfaceCreateWrappedFBONew(context_, 0u, kImpellerPixelFormatRGBA8888, &size);
  if (!surface_) return fail("wrap-fbo");
  if (swapInterval_ >= 0) setSwapInterval(swapInterval_);
  installRecordHooks(rasterThread);
  rni::ioegl::StartFromCurrent();
  rni::ctxlossgl::ReportRobustness("rebuild");
  return true;
#endif
}

void GlfwSurface::rebuildTypography() {
  // Bind the new one before releasing the old: anything still holding the old
  // handle is then a use-after-free ASan reports, never a silent alias of the
  // new context at the same address.
  ImpellerTypographyContext fresh = ImpellerTypographyContextNew();
  if (fresh == nullptr) return;
  ImpellerTypographyContext old = typography_;
  rni::typography::Unbind(old);
  rni::typography::Bind(fresh);
  typography_ = fresh;
  if (old) ImpellerTypographyContextRelease(old);
  rni::typography::Invalidate();  // other threads rebuild theirs on next use
}

}  // namespace rni
