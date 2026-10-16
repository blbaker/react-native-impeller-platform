// FP-43: RECORD side of view snapshots. Model: Flutter's UI thread builds the
// boundary's layer tree into a display list (Scene.toImage /
// OffsetLayer.toImage: the subtree alone, translated so the boundary's origin
// is (0,0), at the requested pixel ratio) and hands it to
// SnapshotControllerImpeller::MakeImpellerSnapshot, which renders it into a
// fresh texture on the raster thread. Here the walk records the node's subtree
// (no ancestors, no siblings, no ancestor clips) into its own list, and the
// render + readback ride on this frame's RasterJobs, after the uploads the
// walk itself queued.
#include <algorithm>
#include <chrono>
#include <cmath>

#include "base/GpuAvailability.h"
#include "base/Trace.h"
#include "scenegraph/SceneGraph.h"

namespace rni {

namespace react = facebook::react;

namespace {

// DoMakeRasterSnapshot scales the target down to the max texture size; this is
// the bound the root offscreen uses for the same reason.
constexpr int kMaxSnapshotPx = 8192;

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// Owns one request between RECORD and its raster job. A job dropped unrun
// (frame discarded, GPU unavailable, context lost) requeues the request: the
// StoreTaskForGPU deferral of snapshot_controller_impeller.cc.
struct SnapshotJob {
  std::shared_ptr<SnapshotController> controller;
  SnapshotRequest req;
  ImpellerDisplayList dl{nullptr};
  int w{0}, h{0};  // rendered size: output x factor
  int factor{1};
  SnapshotReadback readback;
  bool ran{false};
  ~SnapshotJob() {
    if (dl) ImpellerDisplayListRelease(dl);
    if (!ran && controller) controller->Requeue(std::move(req));
  }
  bool Run() {
    ran = true;
    TRACE_EVENT0("raster", "Snapshot");
    gpu::Note(gpu::Counter::kSnapshot);
    const int64_t t0 = NowUs();
    std::vector<uint8_t> rgba;
    if (!readback(dl, w, h, &rgba)) {
      controller->Fail(std::move(req), "the offscreen render of the snapshot failed");
      return false;
    }
    controller->Rendered(std::move(req), std::move(rgba), w, h, factor, NowUs() - t0);
    return true;
  }
};

// Output pixels: width/height when given (one of them keeps the aspect), else
// the view's size at the device scale; then clamped like DoMakeRasterSnapshot.
void OutputSize(const SnapshotOptions& o, float wPt, float hPt, float scale, int* pxW,
                int* pxH) {
  double w = wPt * scale, h = hPt * scale;
  if (o.width > 0 && o.height > 0) {
    w = o.width;
    h = o.height;
  } else if (o.width > 0) {
    h = h * o.width / w;
    w = o.width;
  } else if (o.height > 0) {
    w = w * o.height / h;
    h = o.height;
  }
  const double fit = std::min({1.0, kMaxSnapshotPx / w, kMaxSnapshotPx / h});
  *pxW = std::max(1, (int)std::lround(w * fit));
  *pxH = std::max(1, (int)std::lround(h * fit));
}

}  // namespace

void SceneGraph::setSnapshotController(std::shared_ptr<SnapshotController> controller) {
  if (snapshots_) snapshots_->SetWake(nullptr);
  snapshots_ = std::move(controller);
  // A request wakes a frame (ScheduleFrame); it is not damage.
  if (snapshots_) snapshots_->SetWake([this] { bumpRevision(); });
}

ImpellerDisplayList SceneGraph::recordSnapshotLocked(const SceneNode* node, int pxW, int pxH) {
  // Per-walk state the frame's walk owns: a snapshot walk leaves it as it was.
  const int savedPainted = painted_, savedSprites = spritesDrawn_;
  const bool savedSpinning = spinnerAnimating_.load(std::memory_order_relaxed);
  const std::string savedNote = extTextureNote_;
  snapshotWalk_ = true;
  rebuildPaintRegistriesLocked();
  svgUseDepth_ = 0;
  ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
  if (node != nullptr) {
    // The node's own box onto the whole target: its origin at (0,0).
    const auto& f = node->layoutMetrics.frame;
    ImpellerDisplayListBuilderScale(b, (float)pxW / (float)f.size.width,
                                    (float)pxH / (float)f.size.height);
    const react::Tag savedModal = modalWalk_;
    if (node->isModal) modalWalk_ = node->tag;
    paintNode(b, *node, -(float)f.origin.x, -(float)f.origin.y);
    modalWalk_ = savedModal;
  } else {
    // captureScreen: every root and the modals, as paintLocked draws them.
    const float pts = (float)surfacePxW_ / pointScale_;
    const float ptsH = (float)surfacePxH_ / pointScale_;
    ImpellerDisplayListBuilderScale(b, (float)pxW / pts, (float)pxH / ptsH);
    for (auto rootTag : roots_) {
      auto it = nodes_.find(rootTag);
      if (it != nodes_.end()) paintNode(b, it->second, 0, 0);
    }
    paintModalsLocked(b);
  }
  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);
  ImpellerDisplayListBuilderRelease(b);
  snapshotWalk_ = false;
  painted_ = savedPainted;
  spritesDrawn_ = savedSprites;
  spinnerAnimating_.store(savedSpinning, std::memory_order_relaxed);
  extTextureNote_ = savedNote;
  return dl;
}

void SceneGraph::recordSnapshots(RasterJobs* jobs) {
  if (!snapshots_) return;
  std::vector<SnapshotRequest> reqs = snapshots_->TakePending();
  if (reqs.empty()) return;
  TRACE_EVENT0("record", "SnapshotRecord");
  std::lock_guard<std::mutex> lock(mutex_);
  struct JobsScope {
    RasterJobs*& slot;
    ~JobsScope() { slot = nullptr; }
  } jobsScope{jobs_};
  jobs_ = jobs;
  for (auto& r : reqs) {
    if (jobs == nullptr || !gpu_.snapshot) {
      snapshots_->Fail(std::move(r), "snapshots need a GL render backend on this host");
      continue;
    }
    const SceneNode* node = nullptr;
    float wPt = 0, hPt = 0;
    if (r.tag != 0) {
      auto it = nodes_.find(r.tag);
      if (it == nodes_.end()) {
        snapshots_->Fail(std::move(r), "No view found with reactTag: " + std::to_string(r.tag));
        continue;
      }
      node = &it->second;
      wPt = (float)node->layoutMetrics.frame.size.width;
      hPt = (float)node->layoutMetrics.frame.size.height;
    } else {
      wPt = (float)surfacePxW_ / pointScale_;
      hPt = (float)surfacePxH_ / pointScale_;
    }
    if (!(wPt > 0 && hPt > 0)) {
      snapshots_->Fail(std::move(r), "The view has no size (" + std::to_string(wPt) + "x" +
                                         std::to_string(hPt) + "), nothing to capture");
      continue;
    }
    int pxW = 0, pxH = 0;
    OutputSize(r.options, wPt, hPt, pointScale_, &pxW, &pxH);
    // The screen's root supersample (paintTreeSupersampled, same bounds): render
    // at N x so the capture is antialiased the way the screen is.
    const int n = supersample_;
    const bool ss = n >= 2 && gpu_.supersample != nullptr && surfacePxW_ > 0 &&
                    surfacePxW_ * n <= kMaxSnapshotPx && surfacePxH_ * n <= kMaxSnapshotPx &&
                    pxW * n <= kMaxSnapshotPx && pxH * n <= kMaxSnapshotPx;
    auto job = std::make_shared<SnapshotJob>();
    job->controller = snapshots_;
    job->factor = ss ? n : 1;
    job->w = pxW * job->factor;
    job->h = pxH * job->factor;
    if (ss) supersample_ = 0;  // the inner walk paints in place, as the root's does
    job->dl = recordSnapshotLocked(node, job->w, job->h);
    supersample_ = n;
    job->readback = gpu_.snapshot;
    if (job->dl == nullptr) {
      job->ran = true;  // nothing to requeue: the record itself failed
      snapshots_->Fail(std::move(r), "could not record the view's display list");
      continue;
    }
    std::printf("rn-impeller: snapshot_record id=%llu tag=%d pt=%.1fx%.1f px=%dx%d ss=%d "
                "thread=%s\n",
                (unsigned long long)r.id, r.tag, wPt, hPt, pxW, pxH, job->factor,
                SnapshotThreadLabel().c_str());
    std::fflush(stdout);
    job->req = std::move(r);
    jobs->Add(RasterJobs::Kind::kOffscreen, [job] { return job->Run(); });
  }
}

}  // namespace rni
