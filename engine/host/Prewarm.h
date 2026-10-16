#pragma once

// FP-34: runs the pipeline pre-warm tour once, before the first frame, and reports what it cost.
// Model: impeller/entity/contents/content_context.cc (ContentContext's constructor compiles the
// default pipelines before the first frame is rendered).

#include <cstdint>

#include "scenegraph/GpuBackend.h"

namespace rni {

class FrameTimings;
class GlfwSurface;
class RasterThread;

// Builds the tour on the calling (main) thread and draws it on the raster side into a 1x1 target.
// GL only (Metal and Vulkan compile their default pipelines at context creation); other backends
// print `prewarm skipped=` and return. Prints one `rn-impeller: prewarm ...` line and stamps the
// wall time into `timings`. Returns microseconds, -1 when it did not run.
int64_t RunPrewarmTour(GlfwSurface& surface, RasterThread& raster, GpuBackend backend,
                       FrameTimings& timings);

}  // namespace rni
