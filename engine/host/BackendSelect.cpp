// FP-21: see BackendSelect.h.
#include "host/BackendSelect.h"

#include <cstdio>

namespace rni {

bool ResolveGpuBackend(bool window, bool given, GpuBackend* backend, std::string* error) {
  if (!given) {
#if defined(__APPLE__) && RNI_WITH_WINDOW
    *backend = window ? GpuBackend::kMetal : GpuBackend::kGles;
#else
    *backend = GpuBackend::kGles;
#endif
  } else if (*backend == GpuBackend::kVulkan) {
    *error = "--backend vulkan is not available yet (desktop runs gles; metal on darwin)";
    return false;
  } else if (*backend == GpuBackend::kMetal) {
#if !defined(__APPLE__) || !RNI_WITH_WINDOW
    *error = "--backend metal is darwin-only (windowed)";
    return false;
#else
    if (!window) {
      *error = "--backend metal is windowed-only until FP-23 (headless darwin renders through ANGLE gles)";
      return false;
    }
#endif
  }
  std::printf("rn-impeller: backend_select backend=%s given=%d window=%d\n", GpuBackendName(*backend),
              given ? 1 : 0, window ? 1 : 0);
  std::fflush(stdout);
  return true;
}

}  // namespace rni
