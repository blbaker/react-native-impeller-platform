// Model: flutter/flow/frame_timings.cc (FrameTimingsRecorder).
#include "FrameTimings.h"

#include "base/DevToolsFrames.h"

#include <algorithm>
#include <atomic>
#include <cstdlib>

namespace rni {
namespace {

using Clock = std::chrono::steady_clock;
const Clock::time_point kOrigin = Clock::now();
std::atomic<uint64_t> gFrameNumberGen{1};  // Flutter: frame_number_gen_ = {1}

const char* StateName(FrameTimingsRecorder::State s) {
  switch (s) {
    case FrameTimingsRecorder::State::kUninitialized: return "kUninitialized";
    case FrameTimingsRecorder::State::kVsync: return "kVsync";
    case FrameTimingsRecorder::State::kBuildStart: return "kBuildStart";
    case FrameTimingsRecorder::State::kBuildEnd: return "kBuildEnd";
    case FrameTimingsRecorder::State::kRasterStart: return "kRasterStart";
    case FrameTimingsRecorder::State::kRasterEnd: return "kRasterEnd";
    case FrameTimingsRecorder::State::kPresent: return "kPresent";
  }
  return "?";
}

const char* const kKeys[FrameTimingsRecorder::kStampCount] = {
    "vsync_us", "build_start_us", "build_end_us",
    "raster_start_us", "raster_end_us", "present_us"};

// Nearest-rank percentile of an unsorted copy.
int64_t Pct(std::vector<int64_t> v, int p) {
  if (v.empty()) return 0;
  std::sort(v.begin(), v.end());
  size_t rank = (v.size() * (size_t)p + 99) / 100;
  if (rank == 0) rank = 1;
  return v[rank - 1];
}

}  // namespace

FrameTimingsRecorder::FrameTimingsRecorder()
    : frameNumber_(gFrameNumberGen++) {
  for (int64_t& s : stamps_) s = -1;
}

int64_t FrameTimingsRecorder::stampUs(State s) const {
  if (s == State::kUninitialized) return -1;
  return stamps_[(int)s - 1];
}

void FrameTimingsRecorder::Record(State next) {
  const int64_t now = std::chrono::duration_cast<std::chrono::microseconds>(
                          Clock::now() - kOrigin)
                          .count();
  if ((uint32_t)next != (uint32_t)state_ + 1) {
#ifndef NDEBUG
    fprintf(stderr,
            "rn-impeller: FATAL: frame %llu timing stamp %s while in %s\n",
            (unsigned long long)frameNumber_, StateName(next),
            StateName(state_));
    abort();
#endif
    ++errors_;
  }
  stamps_[(int)next - 1] = now;
  state_ = next;
}

void FrameTimings::Commit(std::unique_ptr<FrameTimingsRecorder> frame) {
  if (!frame) return;
  Rec r{frame->frameNumber(), {}, frame->imageCacheBytes(), frame->nodes()};
  for (int i = 0; i < FrameTimingsRecorder::kStampCount; ++i) {
    r.us[i] = frame->stampUs((FrameTimingsRecorder::State)(i + 1));
  }
  {
    std::lock_guard<std::mutex> lock(mu_);
    errors_ += frame->errors();
    if (frame->state() != FrameTimingsRecorder::State::kPresent) ++errors_;
    recs_.push_back(r);
  }
  // FP-54: the same record goes to React Native DevTools while a trace records.
  const int64_t beginUs = r.us[0] >= 0 ? r.us[0] : r.us[1];
  if (beginUs >= 0 && r.us[5] >= 0) devtools::OnFrameCommitted({r.frame, kOrigin + std::chrono::microseconds(beginUs),
                              kOrigin + std::chrono::microseconds(r.us[5])});
}

void FrameTimings::Discard(std::unique_ptr<FrameTimingsRecorder> frame) {
  if (!frame) return;
  std::lock_guard<std::mutex> lock(mu_);
  errors_ += frame->errors();
  ++discarded_;
}

std::vector<FrameTimings::Rec> FrameTimings::Snapshot() const {
  std::lock_guard<std::mutex> lock(mu_);
  std::vector<Rec> out;
  out.reserve(recs_.size());
  for (size_t i = 0; i < recs_.size(); ++i) out.push_back(recs_[i]);
  return out;
}

void FrameTimings::PrintSummary(FILE* out) const {
  const std::vector<Rec> recs = Snapshot();
  std::vector<int64_t> build, raster, total;
  int64_t cacheMax = 0;
  for (const Rec& r : recs) {
    build.push_back(r.us[2] - r.us[1]);
    raster.push_back(r.us[4] - r.us[3]);
    total.push_back(r.us[5] - r.us[0]);
    cacheMax = std::max(cacheMax, r.imageCacheBytes);
  }
  int errors, discarded;
  {
    std::lock_guard<std::mutex> lock(mu_);
    errors = errors_;
    discarded = discarded_;
  }
  fprintf(out,
          "rn-impeller: frame_timings n=%zu build_p50=%lld build_p95=%lld "
          "build_p99=%lld raster_p50=%lld raster_p95=%lld raster_p99=%lld "
          "total_p95=%lld frame_timing_errors=%d discarded=%d "
          "image_cache_bytes_max=%lld image_cache_bytes_last=%lld prewarm_us=%lld\n",
          recs.size(), (long long)Pct(build, 50), (long long)Pct(build, 95),
          (long long)Pct(build, 99), (long long)Pct(raster, 50),
          (long long)Pct(raster, 95), (long long)Pct(raster, 99),
          (long long)Pct(total, 95), errors, discarded, (long long)cacheMax,
          (long long)(recs.empty() ? 0 : recs.back().imageCacheBytes), (long long)prewarmUs());
  fflush(out);
}

bool FrameTimings::WriteJson(const std::string& path) const {
  const std::vector<Rec> recs = Snapshot();
  FILE* f = fopen(path.c_str(), "w");
  if (!f) return false;
  fprintf(f, "{\"frames\":[");
  for (size_t i = 0; i < recs.size(); ++i) {
    fprintf(f, "%s\n{\"frame\":%llu", i ? "," : "",
            (unsigned long long)recs[i].frame);
    for (int k = 0; k < FrameTimingsRecorder::kStampCount; ++k) {
      if (recs[i].us[k] < 0) fprintf(f, ",\"%s\":null", kKeys[k]);
      else fprintf(f, ",\"%s\":%lld", kKeys[k], (long long)recs[i].us[k]);
    }
    fprintf(f, ",\"image_cache_bytes\":%lld,\"nodes\":%d}", (long long)recs[i].imageCacheBytes,
            recs[i].nodes);
  }
  fprintf(f, "\n],\"prewarm_us\":%lld}\n", (long long)prewarmUs());
  return fclose(f) == 0;
}

}  // namespace rni
