// FP-13: one frame split into RECORD and RASTER (still on one thread).
//
// Model: Flutter hands an immutable flutter::LayerTree (flow/layers/layer_tree.h)
// plus its FrameTimingsRecorder from the UI thread to the Rasterizer through
// shell/common/pipeline.h (our host/Pipeline.h); Rasterizer::Draw ->
// DrawToSurface turns it into GPU work and presents. Our FrameItem is that
// LayerTree: the ImpellerDisplayList the walk recorded (impeller.h: display
// lists are immutable, thread-safe and context-agnostic), the surface size it
// was recorded for, its frame number and its timings.
//
//   RECORD  RecordFrame(): walk the scene (SceneGraph::paint takes the scene
//           mutex), finish the display list, stamp build end.
//   RASTER  RasterFrame(): stamp raster start, draw the list onto the surface,
//           stamp raster end. The caller presents (windowed) or reads back.
//
// FP-14: RECORD makes no GL call. GPU work the walk needs (supersample
// offscreens, world/sprite/image uploads) rides in `jobs`; RASTER runs it
// before the draw (scenegraph/RasterJobs.h).
#pragma once

#include <cstdint>
#include <functional>
#include <memory>

#include "host/FrameTimings.h"
#include "host/Pipeline.h"
#include "impeller.h"
#include "scenegraph/RasterJobs.h"

namespace rni {

class SceneGraph;

struct FrameItem {
  FrameItem() = default;
  ~FrameItem();
  FrameItem(const FrameItem&) = delete;
  FrameItem& operator=(const FrameItem&) = delete;

  ImpellerDisplayList displayList = nullptr;  // owned; null if the build failed
  int width = 0;   // surface pixels the list was recorded for
  int height = 0;
  int painted = 0;  // nodes the walk visited
  uint64_t frameNumber = 0;  // == timings->frameNumber()
  std::unique_ptr<FrameTimingsRecorder> timings;
  std::unique_ptr<RasterJobs> jobs;  // FP-14: null without a GL context
};

using FramePipeline = Pipeline<FrameItem>;

// Extra drawing appended after the scene (the headless probe banner).
using RecordExtras = std::function<void(ImpellerDisplayListBuilder)>;

// RECORD. `timings` must be in kBuildStart. Never returns null.
std::unique_ptr<FrameItem> RecordFrame(SceneGraph& scene, float pointScale,
                                       int width, int height,
                                       std::unique_ptr<FrameTimingsRecorder> timings,
                                       const RecordExtras& extras = nullptr);

// RASTER. Stamps raster start/end around the item's jobs + draw(displayList);
// false when the item has no display list or draw fails.
bool RasterFrame(FrameItem& item,
                 const std::function<bool(ImpellerDisplayList)>& draw);

// `pipeline depth= produced= consumed= abandoned= refused= max_inflight=`
// plus FP-14's `record_gl ...` line.
void PrintPipelineSummary(const FramePipeline& pipeline);

}  // namespace rni
