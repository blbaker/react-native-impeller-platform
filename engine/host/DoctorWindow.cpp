// The window section of `rn-impeller --doctor` (host/Doctor.h): which GLFW
// backend this machine gets and why, proven by glfwInit itself, plus a probe
// through a HIDDEN window (never mapped, never focused: no compositor shows
// it, kiosk-shell never configures it).
#include "host/Doctor.h"

#if defined(__linux__) && !defined(__ANDROID__)
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <GLFW/glfw3.h>
#include <dlfcn.h>

#include <cstdio>
#include <cstring>
#include <initializer_list>

#include "host/GlfwPlatformSelect.h"
#include "host/HeadlessEglRungs.h"

namespace rni::doctor {
namespace {

std::string gGlfwError;

void OnGlfwError(int code, const char* desc) {
  char b[16];
  std::snprintf(b, sizeof b, "0x%05X", (unsigned)code);
  gGlfwError = std::string(b) + " " + (desc ? desc : "");
}

const char* PlatformName(int p) {
  return p == GLFW_PLATFORM_WAYLAND ? "wayland" : p == GLFW_PLATFORM_X11 ? "x11" : p == GLFW_PLATFORM_NULL ? "null"
                                                                                                         : "other";
}

// GLFW 3.4 loads these itself (src/wl_init.c, src/x11_init.c; first soname of
// each of its lists). Report-only: they are GLFW's lists, not ours, and they
// explain a failed glfwInit on an image that lacks one.
std::string ProbeLibs(std::initializer_list<const char*> sonames) {
  std::string s;
  for (const char* so : sonames) {
    const bool ok = dlopen(so, RTLD_LAZY | RTLD_LOCAL) != nullptr;
    s += (s.empty() ? "" : ",") + std::string(so) + (ok ? ":ok" : ":missing");
  }
  return s;
}

std::string Str(const char* s) { return s ? s : ""; }

void ProbeHiddenWindow(const Emit& emit) {
  glfwDefaultWindowHints();
  glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE);
  glfwWindowHint(GLFW_FOCUSED, GLFW_FALSE);
  glfwWindowHint(GLFW_FOCUS_ON_SHOW, GLFW_FALSE);
  glfwWindowHint(GLFW_DECORATED, GLFW_FALSE);
  // The same context GlfwSurface asks for on linux.
  glfwWindowHint(GLFW_CONTEXT_CREATION_API, GLFW_EGL_CONTEXT_API);
  glfwWindowHint(GLFW_CLIENT_API, GLFW_OPENGL_ES_API);
  glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
  glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 0);
  gGlfwError.clear();
  GLFWwindow* w = glfwCreateWindow(64, 64, "rn-impeller --doctor", nullptr, nullptr);
  if (w == nullptr) {
    emit("window.egl", "fail:" + gGlfwError);
    return;
  }
  glfwMakeContextCurrent(w);
  EGLDisplay d = eglGetCurrentDisplay();
  emit("window.egl", d == EGL_NO_DISPLAY ? "fail:no current EGL display" : "ok");
  if (d != EGL_NO_DISPLAY) {
    emit("window.egl.vendor", Str(eglQueryString(d, EGL_VENDOR)));
    emit("window.egl.version", Str(eglQueryString(d, EGL_VERSION)));
    const char* r = reinterpret_cast<const char*>(glGetString(GL_RENDERER));
    emit("window.gl.renderer", Str(r));
    emit("window.gl.version", Str(reinterpret_cast<const char*>(glGetString(GL_VERSION))));
    const char* cls = RendererClass(r);
    emit("window.gpu.class", cls);
    emit("window.gpu.verdict", std::strcmp(cls, "software") == 0 ? headlessegl::kUnverified : "hardware");
  }
  glfwMakeContextCurrent(nullptr);
  glfwDestroyWindow(w);
}

}  // namespace

void ReportWindow(const Emit& emit) {
  const GlfwPlatformChoice pc = ChooseGlfwPlatform(GLFW_PLATFORM_X11, GLFW_PLATFORM_WAYLAND);
  emit("window.order", "RNI_GLFW_PLATFORM>XDG_SESSION_TYPE=wayland>DISPLAY_set_x11>glfw_default_wayland_then_x11");
  emit("window.choice", pc.name);
  emit("window.reason", pc.reason);
  emit("window.compiled", std::string("wayland=") + (glfwPlatformSupported(GLFW_PLATFORM_WAYLAND) ? "1" : "0") +
                              ",x11=" + (glfwPlatformSupported(GLFW_PLATFORM_X11) ? "1" : "0"));
  emit("window.glfw_needs.wayland",
       ProbeLibs({"libwayland-client.so.0", "libwayland-cursor.so.0", "libwayland-egl.so.1", "libxkbcommon.so.0"}));
  emit("window.glfw_needs.x11", ProbeLibs({"libX11.so.6"}));
  emit("window.glfw_optional.x11", ProbeLibs({"libXcursor.so.1", "libXrandr.so.2", "libXinerama.so.1", "libXi.so.6",
                                              "libXext.so.6", "libXrender.so.1", "libX11-xcb.so.1"}));
  glfwSetErrorCallback(OnGlfwError);
  if (pc.hint != 0) glfwInitHint(GLFW_PLATFORM, pc.hint);
  glfwInitHint(GLFW_WAYLAND_LIBDECOR, GLFW_WAYLAND_DISABLE_LIBDECOR);  // as GlfwSurface
  gGlfwError.clear();
  if (!glfwInit()) {
    emit("window.glfw_init", "fail:" + gGlfwError);
    emit("window.platform", "none");
    return;
  }
  emit("window.glfw_init", "ok");
  emit("window.platform", PlatformName(glfwGetPlatform()));
  ProbeHiddenWindow(emit);
  glfwTerminate();
}

}  // namespace rni::doctor
#elif RNI_WITH_WINDOW
namespace rni::doctor {
void ReportWindow(const Emit& emit) { emit("window.glfw_init", "not_reported_on_this_os"); }
}  // namespace rni::doctor
#endif
