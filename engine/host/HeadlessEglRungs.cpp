#include "host/HeadlessEglRungs.h"

#if defined(__linux__) && !defined(__ANDROID__)
#include "host/OptionalLibs.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace rni::headlessegl {
namespace {

constexpr EGLenum kEglPlatformGbm = 0x31D7;  // EGL_PLATFORM_GBM_KHR

std::string EglErr() {
  char b[32];
  std::snprintf(b, sizeof b, "egl_error=0x%04X", (unsigned)eglGetError());
  return b;
}

bool HasToken(const std::string& list, const char* tok) {
  const size_t n = std::strlen(tok);
  for (size_t p = list.find(tok); p != std::string::npos; p = list.find(tok, p + 1)) {
    const bool startOk = p == 0 || list[p - 1] == ' ';
    const bool endOk = p + n == list.size() || list[p + n] == ' ';
    if (startOk && endOk) return true;
  }
  return false;
}

using GetPlatformDisplay = PFNEGLGETPLATFORMDISPLAYEXTPROC;

// Each Try* returns the initialised display or EGL_NO_DISPLAY with r->result
// and r->verdict saying why.
EGLDisplay TrySurfaceless(GetPlatformDisplay gpd, const Report& rep, Rung* r, EGLint* ma, EGLint* mi) {
  r->verdict = "fail";
  if (gpd == nullptr) { r->result = "fail:eglGetPlatformDisplayEXT unavailable"; return EGL_NO_DISPLAY; }
  if (!HasToken(rep.clientExtensions, "EGL_MESA_platform_surfaceless")) {
    r->result = "fail:client extension EGL_MESA_platform_surfaceless absent (not Mesa)";
    return EGL_NO_DISPLAY;
  }
  EGLDisplay d = gpd(EGL_PLATFORM_SURFACELESS_MESA, reinterpret_cast<void*>(EGL_DEFAULT_DISPLAY), nullptr);
  if (d == EGL_NO_DISPLAY) { r->result = "fail:eglGetPlatformDisplay returned EGL_NO_DISPLAY " + EglErr(); return d; }
  if (!eglInitialize(d, ma, mi)) { r->result = "fail:eglInitialize " + EglErr(); return EGL_NO_DISPLAY; }
  r->result = r->verdict = "ok";
  return d;
}

EGLDisplay TryGbm(GetPlatformDisplay gpd, Report* rep, Rung* r, EGLint* ma, EGLint* mi) {
  r->verdict = "fail";
  // The device first: with no DRM node this machine cannot run the rung at all
  // (qemu, containers, WSL), which is UNVERIFIED, not a defect of the image.
  const char* env = std::getenv("RNI_DRM_RENDER_NODE");
  const char* nodes[] = {env, "/dev/dri/renderD128", "/dev/dri/renderD129", "/dev/dri/card0"};
  std::string tried, why;
  std::vector<std::pair<int, const char*>> open_;
  for (const char* n : nodes) {
    if (n == nullptr || *n == '\0') continue;
    tried += (tried.empty() ? "" : ",") + std::string(n);
    const int fd = open(n, O_RDWR | O_CLOEXEC);
    if (fd >= 0) open_.push_back({fd, n});
  }
  if (open_.empty()) {
    r->result = "fail:no DRM node could be opened (tried " + tried + ")";
    r->verdict = kUnverified;
    return EGL_NO_DISPLAY;
  }
  auto closeAll = [&] { for (auto& p : open_) close(p.first); };
  const optlib::Opened lib = optlib::Open("gbm");
  if (lib.handle == nullptr) {
    closeAll();
    r->result = "fail:libgbm not loadable (tried " + lib.tried + ": " + lib.error + ")";
    return EGL_NO_DISPLAY;
  }
  using CreateFn = void* (*)(int);
  auto create = reinterpret_cast<CreateFn>(dlsym(lib.handle, "gbm_create_device"));
  if (create == nullptr) { closeAll(); r->result = "fail:gbm_create_device missing in " + lib.soname; return EGL_NO_DISPLAY; }
  if (gpd == nullptr) { closeAll(); r->result = "fail:eglGetPlatformDisplayEXT unavailable"; return EGL_NO_DISPLAY; }
  if (!HasToken(rep->clientExtensions, "EGL_KHR_platform_gbm") &&
      !HasToken(rep->clientExtensions, "EGL_MESA_platform_gbm")) {
    closeAll();
    r->result = "fail:client extension EGL_KHR_platform_gbm absent";
    return EGL_NO_DISPLAY;
  }
  for (size_t i = 0; i < open_.size(); ++i) {
    const auto [fd, node] = open_[i];
    void* dev = create(fd);
    if (dev == nullptr) { why += std::string(why.empty() ? "" : "; ") + node + ": gbm_create_device failed"; continue; }
    EGLDisplay d = gpd(kEglPlatformGbm, dev, nullptr);
    if (d == EGL_NO_DISPLAY) { why += std::string(why.empty() ? "" : "; ") + node + ": EGL_NO_DISPLAY " + EglErr(); continue; }
    if (!eglInitialize(d, ma, mi)) { why += std::string(why.empty() ? "" : "; ") + node + ": eglInitialize " + EglErr(); continue; }
    // The fd and the gbm device live as long as the process; so does the display.
    for (size_t j = 0; j < open_.size(); ++j) if (j != i) close(open_[j].first);
    rep->gbmNode = node;
    std::fprintf(stderr, "rn-impeller: headless gbm device %s\n", node);
    r->result = r->verdict = "ok";
    return d;
  }
  r->result = "fail:" + why;
  return EGL_NO_DISPLAY;  // fds stay open: a gbm device may still reference them
}

EGLDisplay TryDefault(Rung* r, EGLint* ma, EGLint* mi) {
  r->verdict = "fail";
  EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (d == EGL_NO_DISPLAY) { r->result = "fail:eglGetDisplay(EGL_DEFAULT_DISPLAY) returned EGL_NO_DISPLAY " + EglErr(); return d; }
  if (!eglInitialize(d, ma, mi)) { r->result = "fail:eglInitialize " + EglErr(); return EGL_NO_DISPLAY; }
  r->result = r->verdict = "ok";
  return d;
}

}  // namespace

Report& Last() {
  static Report r;
  return r;
}

bool ForcePbuffer() {
  const char* v = std::getenv("RNI_EGL_FORCE_PBUFFER");
  return v != nullptr && std::strcmp(v, "1") == 0;
}

void* OpenDisplay() {
  Report& rep = Last();
  rep = Report{};
  if (const char* w = std::getenv("RNI_EGL_PLATFORM"); w != nullptr && *w != '\0') rep.forced = w;
  // Client extensions need EGL 1.5 or EGL_EXT_client_extensions; nullptr otherwise.
  const char* ce = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
  rep.clientExtensions = ce ? ce : "";
  eglGetError();  // a nullptr above leaves EGL_BAD_DISPLAY behind; don't blame a rung for it
  auto gpd = reinterpret_cast<GetPlatformDisplay>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
  EGLDisplay dpy = EGL_NO_DISPLAY;
  EGLint ma = 0, mi = 0;
  for (const char* name : {"surfaceless", "gbm", "default"}) {
    Rung r{name, "", ""};
    if (!rep.forced.empty() && rep.forced != name) {
      r.result = "skipped:RNI_EGL_PLATFORM=" + rep.forced;
      r.verdict = "skipped";
    } else if (dpy != EGL_NO_DISPLAY) {
      r.result = "skipped:" + rep.took + " already took the display";
      r.verdict = "skipped";
    } else {
      EGLDisplay d = std::strcmp(name, "surfaceless") == 0 ? TrySurfaceless(gpd, rep, &r, &ma, &mi)
                     : std::strcmp(name, "gbm") == 0       ? TryGbm(gpd, &rep, &r, &ma, &mi)
                                                           : TryDefault(&r, &ma, &mi);
      if (d != EGL_NO_DISPLAY) {
        dpy = d;
        rep.took = name;
        rep.major = ma;
        rep.minor = mi;
      }
    }
    rep.rungs.push_back(r);
  }
  return dpy == EGL_NO_DISPLAY ? nullptr : dpy;
}

}  // namespace rni::headlessegl
#endif
