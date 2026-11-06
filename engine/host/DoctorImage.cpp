// `rn-impeller --doctor`, image sections (linux matrix M7, docs/IMAGE-REQUIREMENTS.md).
//
//   webhelper.*  where the web view helper is found (WebHelperLink::Resolve, the
//                lookup the web view itself uses) and whether it STARTS: the
//                doctor runs `<helper> --version`. Reaching the helper's main
//                means the dynamic loader resolved WPE WebKit + WPEPlatform and
//                everything they need, so a missing WPE library is named here.
//   image.*      the image contract in one place. The libraries the engine
//                NEEDs (DT_NEEDED) are loaded before the doctor runs; when one
//                is missing the loader names it and nothing here prints. The
//                libraries the engine only dlopens are checked one by one:
//                required ones decide image.status, optional ones are reported.
//
// Keys are only ever added (Mac, 2026-10-19: no renames).
#include <dlfcn.h>
#include <elf.h>
#include <link.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "host/Doctor.h"
#include "video/VideoPlayer.h"
#include "webview/WebHelperLink.h"

namespace rni::doctor {
namespace {

std::string ExeDir() {
  char buf[4096];
  const ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
  if (n <= 0) return "";
  buf[n] = 0;
  std::string p = buf;
  const size_t s = p.rfind('/');
  return s == std::string::npos ? "" : p.substr(0, s);
}

// First line the command prints (stdout + stderr), and its exit status.
std::string RunFirstLine(const std::string& cmd, int* status) {
  FILE* p = popen((cmd + " 2>&1").c_str(), "r");
  if (p == nullptr) {
    *status = -1;
    return "popen failed";
  }
  std::string first;
  char line[1024];
  while (std::fgets(line, sizeof line, p) != nullptr)
    if (first.empty()) first = line;
  const int rc = pclose(p);
  *status = WIFEXITED(rc) ? WEXITSTATUS(rc) : 128 + (WIFSIGNALED(rc) ? WTERMSIG(rc) : 0);
  while (!first.empty() && (first.back() == '\n' || first.back() == '\r')) first.pop_back();
  return first;
}

// The image's libraries the engine dlopens. Required: without them the engine
// has no window (GLFW's Wayland backend refuses to init) or no system fonts.
struct Need {
  const char* soname;
  const char* use;
};
constexpr Need kRequired[] = {
    {"libwayland-cursor.so.0", "GLFW Wayland backend"},
    {"libwayland-egl.so.1", "GLFW Wayland backend"},
    {"libxkbcommon.so.0", "GLFW Wayland backend"},
    {"libfontconfig.so.1", "system font lookup"},
};
constexpr Need kOptional[] = {
    {"libX11.so.6", "x11"},
    {"libgbm.so.1", "gbm"},
};

bool Loads(const char* soname) {
  void* h = dlopen(soname, RTLD_NOW | RTLD_LOCAL);
  if (h == nullptr) return false;
  dlclose(h);
  return true;
}

// This binary's own DT_NEEDED list, read from its dynamic section.
std::string OwnNeeded() {
  std::string out;
  const char* strtab = nullptr;
  for (const ElfW(Dyn)* d = _DYNAMIC; d->d_tag != DT_NULL; ++d)
    if (d->d_tag == DT_STRTAB) strtab = reinterpret_cast<const char*>(d->d_un.d_ptr);
  if (strtab == nullptr) return "unknown";
  for (const ElfW(Dyn)* d = _DYNAMIC; d->d_tag != DT_NULL; ++d)
    if (d->d_tag == DT_NEEDED) out += (out.empty() ? "" : ",") + std::string(strtab + d->d_un.d_val);
  return out;
}

}  // namespace

// Returns "ok", "fail:<why>" or "skipped:<why>" for image.optional.webview.
std::string ReportWebHelper(const Emit& emit) {
  const std::string local = ExeDir() + "/rni-webhelper";
  emit("webhelper.tried", "RNI_WEBHELPER," + local);
  if (const char* c = std::getenv("RNI_WEBHELPER"); c && *c) emit("webhelper.resolved", std::string("RNI_WEBHELPER=") + c);
  else emit("webhelper.resolved", access(local.c_str(), X_OK) == 0 ? local : "none");
  emit("webhelper.web_view_in_build", "1");
  std::string command, why;
  if (!WebHelperLink::Resolve(&command, &why)) {
    emit("webhelper.check", "skipped:" + why);
    return "skipped:no rni-webhelper";
  }
  int status = 0;
  const std::string first = RunFirstLine(command + " --version", &status);
  const bool ok = status == 0 && first.rfind("rni-webhelper: version ", 0) == 0;
  const std::string verdict = ok ? "ok:" + first.substr(std::strlen("rni-webhelper: version "))
                                 : "fail:exit " + std::to_string(status) + ": " + first;
  emit("webhelper.check", verdict);
  return ok ? "ok" : "fail:" + first;
}

void ReportImage(const Emit& emit, const std::string& webview) {
  emit("image.needed", OwnNeeded());
  emit("image.needed_status", "ok");  // the doctor is running, so the loader found them all
  std::string req, missing;
  for (const Need& n : kRequired) {
    req += (req.empty() ? "" : ",") + std::string(n.soname);
    if (!Loads(n.soname)) missing += (missing.empty() ? "" : ",") + std::string(n.soname);
  }
  emit("image.required", req);
  emit("image.missing", missing.empty() ? "none" : missing);
  for (const Need& n : kOptional)
    emit(std::string("image.optional.") + n.use, Loads(n.soname) ? "ok" : std::string("missing:") + n.soname);
  const std::string video = VideoLoadError();
  emit("image.optional.video", video.empty() ? "ok:ffmpeg " + std::to_string(VideoFfmpegAbi()) : "unusable");
  emit("image.optional.webview", webview);
  emit("image.status", missing.empty() ? "ok" : "incomplete");
}

}  // namespace rni::doctor
