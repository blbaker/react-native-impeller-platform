#include "host/OptionalLibs.h"

#include <cstring>

#if defined(__linux__) || defined(__APPLE__)
#include <dlfcn.h>
#endif

namespace rni::optlib {
namespace {

// ⛔ ONE PLACE. A loader that keeps its own soname literal next to this table
// is exactly the drift the doctor exists to catch: the doctor would report the
// table while the engine loaded something else.
const Lib kLibs[] = {
    {"libX11", "X11 platform views (GLFW's X11 backend loads its own copy)",
     {"libX11.so.6", nullptr}},
    {"libXext", "shaped X11 platform-view overlays", {"libXext.so.6", nullptr}},
    {"fontconfig", "system font fallback and fontFamily matching",
     {"libfontconfig.so.1", nullptr}},
    {"gbm", "the GBM headless EGL rung (libmali has no surfaceless platform)",
     {"libgbm.so.1", nullptr}},
    {"asound", "video sound (ALSA output)", {"libasound.so.2", nullptr}},
};

// Majors from each release's libav*/version_major.h (n6.1, n7.1, n8.0.1).
const FfmpegSet kFfmpeg[] = {
    {8, 62, {"libavutil.so.60", "libavcodec.so.62", "libavformat.so.62", "libswscale.so.9"}},
    {7, 61, {"libavutil.so.59", "libavcodec.so.61", "libavformat.so.61", "libswscale.so.8"}},
    {6, 60, {"libavutil.so.58", "libavcodec.so.60", "libavformat.so.60", "libswscale.so.7"}},
};

// libswresample per release (video sound only: video plays without it).
// libswresample/version_major.h at n6.1, n7.1, n8.0.1.
const struct {
  int release;
  const char* soname;
} kSwresample[] = {{8, "libswresample.so.6"}, {7, "libswresample.so.5"}, {6, "libswresample.so.4"}};

}  // namespace

const char* SwresampleForRelease(int release) {
  for (const auto& s : kSwresample)
    if (s.release == release) return s.soname;
  return nullptr;
}

const Lib* All(size_t* count) {
  *count = sizeof(kLibs) / sizeof(kLibs[0]);
  return kLibs;
}

const Lib* Find(const char* key) {
  for (const Lib& l : kLibs)
    if (std::strcmp(l.key, key) == 0) return &l;
  return nullptr;
}

Opened Open(const char* key) {
  Opened o;
  const Lib* lib = Find(key);
  if (lib == nullptr) {
    o.error = std::string("no optional-library entry named ") + key;
    return o;
  }
  for (const char* so : lib->sonames) {
    if (so == nullptr) break;
    if (!o.tried.empty()) o.tried += ',';
    o.tried += so;
#if defined(__linux__) || defined(__APPLE__)
    if (void* h = dlopen(so, RTLD_NOW | RTLD_LOCAL)) {
      o.handle = h;
      o.soname = so;
      o.error.clear();
      return o;
    }
    const char* e = dlerror();
    o.error = e ? e : "dlopen failed";
#else
    o.error = "dlopen not available on this platform";
#endif
  }
  return o;
}

const FfmpegSet* FfmpegSets(size_t* count) {
  *count = sizeof(kFfmpeg) / sizeof(kFfmpeg[0]);
  return kFfmpeg;
}

const FfmpegSet* FfmpegSetForRelease(int release) {
  for (const FfmpegSet& s : kFfmpeg)
    if (s.release == release) return &s;
  return nullptr;
}

}  // namespace rni::optlib
