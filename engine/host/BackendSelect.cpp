// FP-21: see BackendSelect.h.
#include "host/BackendSelect.h"

#include <cstdio>

#include "host/HeadlessSurface.h"  // RNI_HEADLESS_METAL (FP-23)

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
    *error = "--backend metal is darwin-only";
    return false;
#else
#if !RNI_HEADLESS_METAL
    if (!window) {
      *error = "--backend metal headless needs SDK patch 0005 (ImpellerSurfaceReadPixels); this SDK lacks it";
      return false;
    }
#endif
#endif
  }
  std::printf("rn-impeller: backend_select backend=%s given=%d window=%d\n", GpuBackendName(*backend),
              given ? 1 : 0, window ? 1 : 0);
  std::fflush(stdout);
  return true;
}

}  // namespace rni
