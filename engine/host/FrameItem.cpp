// FP-13 RECORD / RASTER. See FrameItem.h (model: shell/common/rasterizer.cc).
#include "host/FrameItem.h"

#include <cstdio>

#include "base/Trace.h"
#include "host/RecordNoGl.h"
#include "scenegraph/SceneGraph.h"

namespace rni {

FrameItem::~FrameItem() {
  if (displayList) ImpellerDisplayListRelease(displayList);
  if (fullList) ImpellerDisplayListRelease(fullList);
}

std::unique_ptr<FrameItem> RecordFrame(SceneGraph& scene, float pointScale,
                                       int width, int height,
                                       std::unique_ptr<FrameTimingsRecorder> timings,
                                       const RecordExtras& extras,
                                       bool allowPartial) {
  auto item = std::make_unique<FrameItem>();
  item->width = width;
  item->height = height;
  item->frameNumber = timings ? timings->frameNumber() : 0;
  TRACE_EVENT1("record", "Record", "frame", item->frameNumber);
  recordgl::RecordScope noGl;  // FP-14: no context current, no GL call
  item->jobs = scene.makeRasterJobs();
  ImpellerDisplayListBuilder builder = ImpellerDisplayListBuilderNew(nullptr);
  FrameDamage& damage = item->damage;
  damage.surfaceW = width;
  damage.surfaceH = height;
  damage.scale = pointScale;
  // FP-18: the culled walk (only nodes that reach the damage) for the clip.
  ImpellerDisplayListBuilder culled =
      allowPartial && !extras ? ImpellerDisplayListBuilderNew(nullptr) : nullptr;
  {
    TRACE_EVENT0("paint", "PaintWalk");
    item->painted = scene.paint(builder, pointScale, item->jobs.get(), &damage, culled);
  }
  item->extTextures = scene.takeExternalTextureNote();
  // FP-43: queued snapshots record after the walk; their jobs run after its uploads.
  scene.recordSnapshots(item->jobs.get());
  if (extras) extras(builder);
  {
    TRACE_EVENT0("paint", "DisplayListBuild");
    item->displayList = ImpellerDisplayListBuilderCreateDisplayListNew(builder);
  }
  // The list holds what it needs; the builder is RECORD-only scratch.
  ImpellerDisplayListBuilderRelease(builder);
  // Extras (the probe banner) are not in the damage.
  if (damage.partial && (!allowPartial || extras || !item->displayList)) {
    damage.partial = false;
    damage.reason = allowPartial ? "extras" : "disabled";
  }
  if (damage.partial) {
    // FP-18 (flow/compositor_context.cc PaintLayerTreeImpeller: ClipRect then
    // paint). Device coordinates, NOT translated to the damage origin: a
    // translated list flips pixel-centre ties on edges (1 px of a spinning box
    // differed from the full repaint), so RASTER draws it into a full-size target.
    TRACE_EVENT0("paint", "DamageClip");
    ImpellerDisplayListBuilder clip = ImpellerDisplayListBuilderNew(nullptr);
    const ImpellerRect r = {(float)damage.x, (float)damage.y, (float)damage.w, (float)damage.h};
    ImpellerDisplayListBuilderClipRect(clip, &r, kImpellerClipOperationIntersect);
    ImpellerDisplayList inside =
        damage.w > 0 && damage.h > 0 ? ImpellerDisplayListBuilderCreateDisplayListNew(culled) : nullptr;
    if (inside) {
      ImpellerDisplayListBuilderDrawDisplayList(clip, inside, 1.0f);
      ImpellerDisplayListRelease(inside);
    }
    item->fullList = item->displayList;
    item->displayList = ImpellerDisplayListBuilderCreateDisplayListNew(clip);
    ImpellerDisplayListBuilderRelease(clip);
    if (!item->displayList) {
      item->displayList = item->fullList;
      item->fullList = nullptr;
      damage.partial = false;
      damage.reason = "clip_failed";
    }
  }
  if (culled) ImpellerDisplayListBuilderRelease(culled);
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
  if (item.jobs) item.jobs->AfterRaster();  // FP-20: GL tops up names for the next RECORD
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
