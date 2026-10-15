// FP-13 RECORD / RASTER. See FrameItem.h (model: shell/common/rasterizer.cc).
#include "host/FrameItem.h"

#include <cstdio>

#include "base/Trace.h"
#include "host/RecordNoGl.h"
#include "scenegraph/SceneGraph.h"

namespace rni {

FrameItem::~FrameItem() {
  if (displayList) ImpellerDisplayListRelease(displayList);
}

std::unique_ptr<FrameItem> RecordFrame(SceneGraph& scene, float pointScale,
                                       int width, int height,
                                       std::unique_ptr<FrameTimingsRecorder> timings,
                                       const RecordExtras& extras) {
  auto item = std::make_unique<FrameItem>();
  item->width = width;
  item->height = height;
  item->frameNumber = timings ? timings->frameNumber() : 0;
  TRACE_EVENT1("record", "Record", "frame", item->frameNumber);
  recordgl::RecordScope noGl;  // FP-14: no context current, no GL call
  item->jobs = scene.makeRasterJobs();
  ImpellerDisplayListBuilder builder = ImpellerDisplayListBuilderNew(nullptr);
  {
    TRACE_EVENT0("paint", "PaintWalk");
    item->painted = scene.paint(builder, pointScale, item->jobs.get());
  }
  if (extras) extras(builder);
  {
    TRACE_EVENT0("paint", "DisplayListBuild");
    item->displayList = ImpellerDisplayListBuilderCreateDisplayListNew(builder);
  }
  // The list holds what it needs; the builder is RECORD-only scratch.
  ImpellerDisplayListBuilderRelease(builder);
  if (timings) timings->RecordBuildEnd();
  item->timings = std::move(timings);
  return item;
}

bool RasterFrame(FrameItem& item,
                 const std::function<bool(ImpellerDisplayList)>& draw) {
  TRACE_EVENT1("raster", "Raster", "frame", item.frameNumber);
  if (item.timings) item.timings->RecordRasterStart();
  recordgl::RasterScope gl;
  // FP-14: the textures this list samples are filled before it is drawn.
  if (item.jobs) item.jobs->Run();
  bool ok = false;
  if (item.displayList) {
    TRACE_EVENT0("raster", "Draw");
    ok = draw(item.displayList);
  }
  if (item.jobs) {
    item.jobs->pool().Refill();  // names for the next RECORD
    recordgl::NoteStarved(item.jobs->pool().starved());
  }
  if (item.timings) item.timings->RecordRasterEnd();
  return ok;
}

void PrintPipelineSummary(const FramePipeline& pipeline) {
  const FramePipeline::Stats s = pipeline.stats();
  printf("rn-impeller: pipeline depth=%u produced=%llu consumed=%llu "
         "abandoned=%llu refused=%llu max_inflight=%u\n",
         s.depth, (unsigned long long)s.produced,
         (unsigned long long)s.consumed, (unsigned long long)s.abandoned,
         (unsigned long long)s.refused, s.maxInflight);
  fflush(stdout);
  recordgl::PrintSummary();
}

}  // namespace rni
