#include "host/Prewarm.h"

#include <chrono>
#include <cstdio>

#include "base/ProgramCount.h"
#include "base/Trace.h"
#include "host/FrameTimings.h"
#include "host/GlfwSurface.h"
#include "host/RasterThread.h"
#include "scenegraph/GpuBackendGl.h"
#include "scenegraph/PrewarmTour.h"

namespace rni {

int64_t RunPrewarmTour(GlfwSurface& surface, RasterThread& raster, GpuBackend backend,
                       FrameTimings& timings) {
  using programcount::Phase;
  struct FramesPhase {  // whatever happens below, later links are frame-path links
    ~FramesPhase() { programcount::SetPhase(Phase::kFrames); }
  } framesPhase;
  if (backend != GpuBackend::kGles) {
    std::printf("rn-impeller: prewarm skipped=backend-%s\n", GpuBackendName(backend));
    std::fflush(stdout);
    return -1;
  }
  programcount::SetPhase(Phase::kTour);
  const auto t0 = std::chrono::steady_clock::now();
  ImpellerTexture texture = nullptr;
  raster.PostSync([&] { texture = MakePrewarmTexture(surface.context()); });
  PrewarmCounts counts;
  ImpellerDisplayList dl = BuildPrewarmTour(surface.typography(), texture, &counts);
  bool drawn = false;
  raster.PostSync([&] {
    drawn = dl != nullptr && GlPrewarmDraw(surface.context(), dl);
    if (texture) ImpellerTextureRelease(texture);
  });
  if (dl) ImpellerDisplayListRelease(dl);
  const int64_t us = std::chrono::duration_cast<std::chrono::microseconds>(
                         std::chrono::steady_clock::now() - t0)
                         .count();
  if (!drawn) {
    std::printf("rn-impeller: prewarm skipped=draw-failed\n");
    std::fflush(stdout);
    return -1;
  }
  timings.SetPrewarmUs(us);
  std::printf("rn-impeller: prewarm us=%lld draws=%d blend_modes=%d clips=%d layers=%d blurs=%d "
              "gradients=%d text_styles=%d textures=%d\n",
              (long long)us, counts.draws, counts.blendModes, counts.clips, counts.layers,
              counts.blurs, counts.gradients, counts.textStyles, counts.textures);
  std::fflush(stdout);
  return us;
}

}  // namespace rni
