#include "host/Doctor.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#if defined(__linux__) && !defined(__ANDROID__)
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/utsname.h>
#include <unistd.h>

#include <cerrno>

#include "host/HeadlessEglRungs.h"
#include "host/HeadlessSurface.h"
#include "host/OptionalLibs.h"
#include "video/VideoPlayer.h"
#endif

namespace rni::doctor {

bool Requested(int argc, char** argv) {
  for (int i = 1; i < argc; ++i)
    if (std::strcmp(argv[i], "--doctor") == 0) return true;
  return false;
}

const char* RendererClass(const char* r) {
  if (r == nullptr) return "unknown";
  for (const char* sw : {"llvmpipe", "softpipe", "swrast", "SwiftShader", "Software Rasterizer"})
    if (std::strstr(r, sw) != nullptr) return "software";
  return "hardware";
}

#if !RNI_WITH_WINDOW
void ReportWindow(const Emit& emit) { emit("window.glfw_init", "not_built"); }
#endif

#if defined(__linux__) && !defined(__ANDROID__)
namespace {

std::string Str(const char* s) { return s ? s : ""; }

std::string ExePath() {
  char buf[4096];
  const ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
  if (n <= 0) return "";
  buf[n] = 0;
  return buf;
}

void ReportEgl(const Emit& emit) {
  HeadlessSurface surface;
  std::string err;
  const bool ok = surface.init(16, 16, &err);
  const headlessegl::Report& r = headlessegl::Last();
  emit("egl.forced", r.forced.empty() ? "unset" : r.forced);
  emit("egl.ladder", "surfaceless,gbm,default");
  emit("egl.client_extensions", r.clientExtensions);
  for (const headlessegl::Rung& g : r.rungs) {
    emit("egl.rung." + g.name, g.result);
    emit("egl.rung." + g.name + ".verdict", g.verdict);
  }
  emit("egl.platform", r.took);
  if (!r.gbmNode.empty()) emit("egl.gbm_node", r.gbmNode);
  emit("egl.headless_init", ok ? "ok" : "fail:" + err);
  if (!ok) return;
  emit("egl.current", r.current);
  EGLDisplay d = eglGetCurrentDisplay();
  const std::string ver = Str(eglQueryString(d, EGL_VERSION));
  emit("egl.version", ver.empty() ? std::to_string(r.major) + "." + std::to_string(r.minor) : ver);
  emit("egl.vendor", Str(eglQueryString(d, EGL_VENDOR)));
  emit("egl.client_apis", Str(eglQueryString(d, EGL_CLIENT_APIS)));
  const std::string ext = Str(eglQueryString(d, EGL_EXTENSIONS));
  emit("egl.extensions", ext);
  // The run-time checks the vendor-specific paths (M4 dmabuf, OES) sit behind.
  for (const char* e : {"EGL_KHR_surfaceless_context", "EGL_EXT_image_dma_buf_import",
                        "EGL_EXT_image_dma_buf_import_modifiers", "EGL_KHR_image_base"})
    emit(std::string("egl.has.") + e, (" " + ext + " ").find(std::string(" ") + e + " ") != std::string::npos ? "1" : "0");
  const char* renderer = reinterpret_cast<const char*>(glGetString(GL_RENDERER));
  emit("gl.vendor", Str(reinterpret_cast<const char*>(glGetString(GL_VENDOR))));
  emit("gl.renderer", Str(renderer));
  emit("gl.version", Str(reinterpret_cast<const char*>(glGetString(GL_VERSION))));
  GLint n = 0;
  glGetIntegerv(GL_NUM_EXTENSIONS, &n);
  emit("gl.extensions_count", std::to_string(n));
  bool oes = false;
  for (GLint i = 0; i < n; ++i) {
    const char* e = reinterpret_cast<const char*>(glGetStringi(GL_EXTENSIONS, (GLuint)i));
    if (e && std::strcmp(e, "GL_OES_EGL_image_external") == 0) oes = true;
  }
  emit("gl.has.GL_OES_EGL_image_external", oes ? "1" : "0");
  const char* cls = RendererClass(renderer);
  emit("gpu.class", cls);
  // A software rasterizer proves the code path, never the GPU (no board).
  emit("gpu.verdict", std::strcmp(cls, "software") == 0 ? headlessegl::kUnverified : "hardware");
}

void ReportDlopen(const Emit& emit) {
  size_t n = 0;
  const optlib::Lib* libs = optlib::All(&n);
  for (size_t i = 0; i < n; ++i) {
    const optlib::Opened o = optlib::Open(libs[i].key);
    const std::string k = std::string("dlopen.") + libs[i].key;
    emit(k + ".tried", o.tried);
    emit(k + ".resolved", o.handle ? o.soname : "none");
    if (!o.handle) {
      emit(k + ".error", o.error);
      emit(k + ".missing_means", std::string("no ") + libs[i].use);
    }
  }
  // ffmpeg: one set of four per release, newest first.
  const optlib::FfmpegSet* sets = optlib::FfmpegSets(&n);
  std::string tried, resolved = "none";
  for (size_t i = 0; i < n; ++i) {
    const optlib::FfmpegSet& s = sets[i];
    tried += (tried.empty() ? "" : ",") + std::to_string(s.release) + ":";
    std::string missing;
    for (int j = 0; j < 4; ++j) {
      tried += (j ? "+" : "") + std::string(s.sonames[j]);
      if (missing.empty() && dlopen(s.sonames[j], RTLD_NOW | RTLD_LOCAL) == nullptr) missing = s.sonames[j];
    }
    emit("dlopen.ffmpeg." + std::to_string(s.release), missing.empty() ? "ok" : "missing:" + missing);
    if (missing.empty() && resolved == "none") resolved = std::to_string(s.release);
  }
  emit("dlopen.ffmpeg.tried", tried);
  emit("dlopen.ffmpeg.resolved", resolved);
}

void ReportVideo(const Emit& emit) {
  emit("video.backend", VideoBackendName());
  // The copy that will play video; when none loads, the highest built (the board
  // card 12; docs/IMAGE-REQUIREMENTS.md "ffmpeg 8 as built").
  const int abi = VideoFfmpegAbi();
  emit("video.ffmpeg_abi", abi ? std::to_string(abi) : "none");
  emit("video.ffmpeg_abis_built", VideoFfmpegAbisBuilt());
  const std::string err = VideoLoadError();
  emit("video.status", err.empty() ? "ok" : "unusable:" + err);
}

// . /dev/dma_heap/system is where the web view's frame slots come
// from (card 13); without it they are shared memory. open + close only, nothing
// is allocated. cma = any other heap (not system-uncached), for information:
// the engine never uses it (16 MB CMA on the board). RNI_DOCTOR_DMA_HEAP_DIR is
// the test seam (tools/ci-doctor.sh arm D).
void ReportDmaHeap(const Emit& emit) {
  const char* env = std::getenv("RNI_DOCTOR_DMA_HEAP_DIR");
  const std::string dir = env && *env ? env : "/dev/dma_heap";
  const std::string path = dir + "/system";
  int err = 0;
  const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd >= 0) close(fd);
  else err = errno;
  const char* sys = err == 0 ? "ok" : err == ENOENT ? "enoent" : err == EACCES ? "eacces" : "error";
  bool cma = false;
  if (DIR* d = opendir(dir.c_str())) {
    while (const dirent* e = readdir(d)) {
      const std::string n = e->d_name;
      if (n != "." && n != ".." && n != "system" && n != "system-uncached") cma = true;
    }
    closedir(d);
  }
  emit("dma_heap", std::string("system:") + sys + " cma:" + (cma ? "present" : "absent"));
  const std::string shm = "; without it the web view's frame slots use shared memory";
  if (err == EACCES)
    emit("dma_heap.hint", path + " exists but this user cannot open it (the kernel makes it root-only 0600)." +
                              " Add the udev rule SUBSYSTEM==\"dma_heap\", KERNEL==\"system\", GROUP=\"video\"," +
                              " MODE=\"0660\" and run the engine in group video" + shm);
  else if (err == ENOENT)
    emit("dma_heap.hint", path + " is missing: the kernel needs CONFIG_DMABUF_HEAPS=y and" +
                              " CONFIG_DMABUF_HEAPS_SYSTEM=y" + shm);
  else if (err != 0)
    emit("dma_heap.hint", path + ": " + std::strerror(err) + shm);
}

}  // namespace

int Main(int, char**) {
  // stdout carries ONLY key=value lines. Engine code called below logs to
  // stdout too (HeadlessSurface prints GL_RENDERER), so stdout is pointed at
  // stderr for the run and the report goes to a private copy of the real one.
  std::fflush(stdout);
  FILE* out = fdopen(dup(1), "w");
  if (out == nullptr) return 1;
  dup2(2, 1);
  const Emit emit = [out](const std::string& k, const std::string& v) {
    std::string clean = v;
    for (char& c : clean)
      if (c == '\n' || c == '\r') c = ' ';
    while (!clean.empty() && clean.back() == ' ') clean.pop_back();
    std::fprintf(out, "%s=%s\n", k.c_str(), clean.c_str());
    std::fflush(out);
  };
  utsname u{};
  uname(&u);
  emit("doctor.version", "1");
  emit("doctor.arch", u.machine);
  emit("doctor.exe", ExePath());
  for (const char* k : {"XDG_SESSION_TYPE", "RNI_GLFW_PLATFORM", "WAYLAND_DISPLAY", "DISPLAY",
                        "XDG_RUNTIME_DIR", "RNI_EGL_PLATFORM", "RNI_EGL_FORCE_PBUFFER", "EGL_PLATFORM",
                        "LIBGL_ALWAYS_SOFTWARE"}) {
    const char* v = std::getenv(k);
    emit(std::string("env.") + k, v ? v : "unset");
  }
  ReportWindow(emit);
  ReportEgl(emit);
  ReportDlopen(emit);
  ReportVideo(emit);
  ReportDmaHeap(emit);
  ReportImage(emit, ReportWebHelper(emit));  // host/DoctorImage.cpp
  emit("doctor.done", "1");
  std::fclose(out);
  return 0;
}
#else
int Main(int, char**) {
  std::printf("doctor.version=1\ndoctor.platform=not_reported (the doctor covers linux)\ndoctor.done=1\n");
  return 0;
}
#endif

}  // namespace rni::doctor
