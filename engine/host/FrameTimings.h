// Per-frame timing recorder. Model: flutter/flow/frame_timings.h
// (FrameTimingsRecorder) at our SDK pin: a recorder is created when a frame
// begins, walks a strict state machine, and its summary is handed to a sink
// after the last stamp. Flutter stops at kRasterEnd because the present is the
// rasterizer's last step; our loop presents separately (eglSwapBuffers), so
// kPresent is one extra terminal state.
//
// Out-of-order stamps abort in debug builds (Flutter: FML_DCHECK on the
// RecordXImpl status) and are counted in release builds, where the stamp is
// still written so the record shows the wrong order.
#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace rni {

class FrameTimingsRecorder {
 public:
  enum class State : uint32_t {
    kUninitialized,
    kVsync,
    kBuildStart,
    kBuildEnd,
    kRasterStart,
    kRasterEnd,
    kPresent,
  };
  static constexpr int kStampCount = 6;  // kVsync..kPresent

  FrameTimingsRecorder();  // frame number from a process-wide counter

  void RecordVsync() { Record(State::kVsync); }
  void RecordBuildStart() { Record(State::kBuildStart); }
  void RecordBuildEnd() { Record(State::kBuildEnd); }
  void RecordRasterStart() { Record(State::kRasterStart); }
  void RecordRasterEnd() { Record(State::kRasterEnd); }
  void RecordPresent() { Record(State::kPresent); }

  // FP-33: decoded-image cache size at the present, reported per frame.
  void SetImageCacheBytes(int64_t bytes) { imageCacheBytes_ = bytes; }
  int64_t imageCacheBytes() const { return imageCacheBytes_; }

  // FP-34: nodes the paint walk visited for this frame (gates find the frames a scene change hit).
  void SetNodes(int n) { nodes_ = n; }
  int nodes() const { return nodes_; }

  uint64_t frameNumber() const { return frameNumber_; }
  State state() const { return state_; }
  int errors() const { return errors_; }
  // Microseconds since the recorder clock origin; -1 = never stamped.
  int64_t stampUs(State s) const;

 private:
  void Record(State next);

  const uint64_t frameNumber_;
  State state_ = State::kUninitialized;
  int errors_ = 0;
  int64_t imageCacheBytes_ = 0;
  int nodes_ = 0;
  int64_t stamps_[kStampCount];
};

// Sink for finished recorders (Flutter: the FrameTiming list sent to
// PlatformConfiguration::ReportTimings). Thread-safe.
class FrameTimings {
 public:
  // After RecordPresent. A recorder not in kPresent is counted as an error.
  void Commit(std::unique_ptr<FrameTimingsRecorder> frame);
  // A frame that began but produced nothing to raster (idle-skip). Flutter
  // drops the recorder without a FrameTiming in the same case.
  void Discard(std::unique_ptr<FrameTimingsRecorder> frame);

  // FP-34: wall time of the pipeline pre-warm tour (-1 = it did not run). Reported with the frames.
  void SetPrewarmUs(int64_t us) { prewarmUs_.store(us, std::memory_order_relaxed); }
  int64_t prewarmUs() const { return prewarmUs_.load(std::memory_order_relaxed); }

  // `frame_timings n= build_p50= ... total_p95= frame_timing_errors= discarded=`
  void PrintSummary(FILE* out) const;
  bool WriteJson(const std::string& path) const;

 private:
  struct Rec {
    uint64_t frame;
    int64_t us[FrameTimingsRecorder::kStampCount];
    int64_t imageCacheBytes;
    int nodes;
  };
  std::vector<Rec> Snapshot() const;

  mutable std::mutex mu_;
  std::vector<Rec> recs_;
  int errors_ = 0;
  int discarded_ = 0;
  std::atomic<int64_t> prewarmUs_{-1};
};

}  // namespace rni
