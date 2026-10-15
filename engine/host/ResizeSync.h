// FP-30: resize synchronizer + stale-size discard.
//
// Model: flutter/shell/platform/darwin/macos/framework/Source/ResizeSynchronizer.swift
// (beginResize blocks the platform thread, pumping, until performCommit reports
// a frame at the new size, 1 s cap; no wait before the first frame) and
// flutter/shell/common/shell.cc Shell::ShouldDiscardLayerTree (the rasterizer
// drops a layer tree whose frame size does not satisfy the constraints the
// platform thread set last, rasterizer.cc DoDraw "kDiscarded").
//
// RN difference: Flutter's platform thread waits while the UI thread builds the
// frame. Our platform/main thread IS the recorder, so BeginResize records the
// new-size frame itself (the `produce` callback) before it waits.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>

namespace rni {

class ResizeSync {
 public:
  ResizeSync();

  // Main, when the platform reports a new surface size (Shell::
  // OnPlatformViewSetViewportMetrics sets expected_frame_constraints_).
  void SetExpected(int w, int h);
  // Raster, before drawing an item. True = discard it (logged + counted).
  bool ShouldDiscard(int w, int h, uint64_t frameNumber);
  // Raster, after a present (performCommit).
  void DidPresent(int w, int h);

  enum class Result { kOk, kTimeout, kNoFrameYet, kShutdown };
  // Main. Waits until a frame at w x h presented, at most 1 s (ScaledMs).
  // `produce` records + submits one frame and returns false if it was dropped
  // (pipeline full); it is called until one is submitted. `pump` runs main
  // tasks between waits (pollFlutterMessagesOnce).
  Result BeginResize(int w, int h, const std::function<bool()>& produce,
                     const std::function<void()>& pump);
  // Shutdown: unblocks BeginResize and the test hang (shell.cc OnPlatformViewDestroyed).
  void Shutdown();

  // Raster. Test hook RNI_TEST_RASTER_HANG_AFTER_RESIZE=K: the first item at
  // the size of the K-th BeginResize blocks the raster thread until Shutdown
  // (a GPU that never returns), so the 1 s cap is observable.
  void MaybeHang(int w, int h);

  // The expected size ShouldDiscard last compared against (raster thread).
  void LastChecked(int* w, int* h) const;
  // `resize_sync resizes= ok= timeouts= no_frame_yet= max_wait_us= discarded=`
  void PrintSummary() const;

 private:
  std::atomic<int64_t> expected_{0};   // (w << 32) | h; 0 = no constraint
  std::atomic<int64_t> presented_{0};  // size of the last presented frame
  std::atomic<int64_t> lastChecked_{0};
  std::atomic<bool> didReceiveFrame_{false};
  std::atomic<bool> shutdown_{false};
  std::atomic<uint64_t> discarded_{0};
  mutable std::mutex mu_;
  std::condition_variable cv_;
  int resizes_ = 0, ok_ = 0, timeouts_ = 0, noFrameYet_ = 0;  // main
  int64_t maxWaitUs_ = 0;
  int hangAfter_ = 0;           // RNI_TEST_RASTER_HANG_AFTER_RESIZE
  int64_t hangSize_ = 0;        // guarded by mu_
  bool hung_ = false;           // guarded by mu_
};

}  // namespace rni
