// FP-14 raster-side GPU jobs, backend-neutral since FP-20. See RasterJobs.h.
#include "scenegraph/RasterJobs.h"

#include <algorithm>

#include "base/Trace.h"

namespace rni {

namespace {
std::atomic<uint64_t> gUploads{0}, gOffscreens{0}, gFailed{0};
}  // namespace

RasterJobs::Totals RasterJobs::totals() {
  return {gUploads.load(), gOffscreens.load(), gFailed.load()};
}

RasterJobs::RasterJobs(std::function<void()> afterRaster)
    : afterRaster_(std::move(afterRaster)) {}

RasterJobs::~RasterJobs() {
  if (ran_) return;
  for (Job& j : jobs_) j.flag->store(kJobFailed);  // dropped frame: dependents redo it
}

JobFlag RasterJobs::Add(Kind kind, std::function<bool()> run) {
  jobs_.push_back({kind, std::make_shared<std::atomic<int>>(kJobPending), std::move(run)});
  return jobs_.back().flag;
}

std::vector<std::pair<int, int>> RasterJobs::HalveChain(int w, int h, int nativeW, int nativeH) {
  std::vector<std::pair<int, int>> out;
  int guard = 0;
  while ((w > nativeW * 2 || h > nativeH * 2) && guard++ < 16) {
    w = std::max(nativeW, w / 2);
    h = std::max(nativeH, h / 2);
    out.emplace_back(w, h);
  }
  return out;
}

void RasterJobs::Run() {
  if (jobs_.empty()) {
    ran_ = true;
    return;
  }
  TRACE_EVENT1("raster", "RasterJobs", "jobs", (uint64_t)jobs_.size());
  for (Job& j : jobs_) {
    const bool ok = j.run && j.run();
    j.flag->store(ok ? kJobDone : kJobFailed);
    (j.kind == Kind::kOffscreen ? gOffscreens : gUploads).fetch_add(1, std::memory_order_relaxed);
    if (!ok) gFailed.fetch_add(1, std::memory_order_relaxed);
    j.run = nullptr;  // releases the captures now, not with the frame
  }
  ran_ = true;
}

void RasterJobs::AfterRaster() {
  if (afterRaster_) afterRaster_();
}

}  // namespace rni
