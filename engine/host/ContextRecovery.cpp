#include "host/ContextRecovery.h"

#include <chrono>
#include <string>

#include "base/Trace.h"
#include "host/ContextLoss.h"
#include "host/GlfwSurface.h"
#include "host/WindowRasterizer.h"
#include "scenegraph/SceneGraph.h"

namespace rni {

bool RecoverContext(WindowRasterizer& rasterizer, GlfwSurface& surface, SceneGraph& scene) {
  TRACE_EVENT0("frame", "ContextRecovery");
  const auto t0 = std::chrono::steady_clock::now();
  std::string error;
  // Raster thread, after every frame queued before the loss (dropped).
  if (!rasterizer.RebuildGpu(&error)) {
    ctxloss::Recovered(false, 0, error.empty() ? "rebuild" : error.c_str());
    return false;
  }
  // Every cached texture belonged to the old context; CPU sources stay.
  scene.dropGpuResources();
  // The backend (GL name pool, uploader, supersample) is built where GL is current.
  rasterizer.thread().PostSync([&] { scene.setRenderContext(surface.context()); });
  surface.rebuildTypography();
  const auto us =
      std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - t0)
          .count();
  ctxloss::Recovered(true, us, "gpu+caches+typography");
  return true;
}

}  // namespace rni
