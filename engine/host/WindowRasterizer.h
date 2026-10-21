// FP-15: windowed RASTER on a dedicated thread that owns the GL context.
//
// Model: flutter/shell/common/rasterizer.cc (Rasterizer::Draw consumes the
// pipeline on the raster runner, DrawToSurfaces acquires a frame at the layer
// tree's size and presents) + shell/common/shell.cc (OnAnimatorDraw posts the
// draw to the raster runner; OnPlatformViewDestroyed tears the surface down ON
// the raster thread before the platform thread continues). The platform/main
// thread keeps events, input, mount, NativeAnimated, FrameScheduler and RECORD;
// this class owns the pipeline (depth 2 threaded, 1 inline: animator.cc) and
// everything that touches GL: init, resize of the fbo-0 wrap, jobs + draw,
// readbacks, present, teardown.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "host/FrameItem.h"
#include "host/PartialRepaint.h"
#include "host/Pixel.h"
#include "host/RasterThread.h"

namespace rni {

class FrameScheduler;
class FrameTimings;
class GlfwSurface;
class PlatformViewEmbedder;
class ResizeSync;

class WindowRasterizer {
 public:
  struct Hooks {
    // Raster thread, after the draw and before the present (pixels readable).
    std::function<void(int presentNumber, uint64_t frameNumber)> beforePresent;
    // Raster thread, after the present. presentNumber is 1-based.
    std::function<void(int presentNumber)> afterPresent;
  };

  WindowRasterizer(GlfwSurface& surface, FrameTimings& timings, bool threaded);
  ~WindowRasterizer();  // Shutdown()

  // The raster thread takes the GL context (GlfwSurface::initGpu).
  bool Start(std::string* error);
  void SetScheduler(FrameScheduler* scheduler) { scheduler_ = scheduler; }
  // FP-30: stale-size discard + present reports (Rasterizer::Delegate).
  void SetResizeSync(ResizeSync* sync) { resizeSync_ = sync; }
  void SetHooks(Hooks hooks) { hooks_ = std::move(hooks); }
  // FP-44: native child views composited with each frame (before Start).
  void SetPlatformViewEmbedder(PlatformViewEmbedder* e) { embedder_ = e; }
  // FP-18: --partial-repaint. Before Start; partialRepaint() is the verdict
  // (requested and supported), which RECORD reads to allow a clipped list.
  void SetPartialRepaint(bool on) { partialRequested_ = on; }
  bool partialRepaint() const { return partialEnabled_.load(std::memory_order_acquire); }
  bool threaded() const { return raster_.threaded(); }
  RasterThread& thread() { return raster_; }

  // Main, before a frame's build starts: wait up to `waitMs` for a free slot
  // (the one-thread loop was paced by its own draw + present; this is the
  // same back-pressure). False on timeout.
  bool WaitForSlot(int waitMs);
  // Main. A pipeline slot; when every slot is taken, waits up to `waitMs` for
  // the raster thread to free one (empty continuation on timeout: the caller
  // drops the frame, animator.cc "PipelineFull").
  FramePipeline::ProducerContinuation AcquireSlot(int waitMs);
  // Main. Queues the recorded item and posts its draw (Shell::OnAnimatorDraw).
  // readback: read the frame back before its present (TakeGrab). Returns the
  // item's ticket: items present in submit order, so ticket k has presented
  // once presents() >= k (frame numbers are not in submit order: a refresh
  // paint's recorder can be younger than the loop frame it interrupts).
  uint64_t Submit(FramePipeline::ProducerContinuation slot,
                  std::unique_ptr<FrameItem> item, bool readback);
  // Main. Waits until the item with this ticket presented (or timeout).
  bool WaitPresented(uint64_t ticket, int timeoutMs);
  // Main, after WaitPresented: the pre-present pixels of the last readback item.
  bool TakeGrab(std::vector<Px>* px, int* w, int* h);

  // Test hook (ci-raster-thread): the raster thread sleeps `ms` before drawing
  // the item with this frame number.
  void DelayFrame(uint64_t frameNumber, int ms);

  int presents() const { return presents_.load(std::memory_order_acquire); }
  // FP-30: items finished, presented or discarded (tickets retire in order).
  uint64_t retired() const { return retired_.load(std::memory_order_acquire); }
  // Main. True while a submitted item has not retired yet.
  bool inFlight() const { return retired() < submitted_; }
  // The newest FrameItem::sceneRevision that reached the screen: drawn and
  // presented. Frames that were discarded or failed to draw do not count
  // (host/UnpresentedDamage.h).
  uint64_t presentedRevision() const {
    return presentedRevision_.load(std::memory_order_acquire);
  }
  // Frames retired without reaching the screen, and when the last one did
  // (steady clock us, 0 = never).
  uint64_t lostFrames() const { return lost_.load(std::memory_order_acquire); }
  int64_t lastLostUs() const { return lastLostUs_.load(std::memory_order_acquire); }
  // Mutation-gate switches (tools/mutation-verify-idle-commit-paint.sh), set
  // by --idle-mutant before the loop starts. markLostPresented: a lost frame
  // still advances presentedRevision. noLostWake: a lost frame does not wake
  // the parked loop.
  void SetLostFrameMutants(bool markLostPresented, bool noLostWake) {
    mutantMarkLost_ = markLostPresented;
    mutantNoLostWake_ = noLostWake;
  }
  // Drains queued items (they present), releases the GPU objects ON the raster
  // thread, then joins it. Main; idempotent.
  void Shutdown();
  // FP-32 (Rasterizer::Teardown + Setup), main thread: on the raster thread,
  // after every frame queued before it (dropped while the loss is pending):
  // partial-repaint GL objects, the surface's GPU objects and EGL context are
  // rebuilt. Main then rebuilds what RECORD caches (ContextRecovery.h).
  bool RebuildGpu(std::string* error);
  // `raster_thread threaded= depth= ... draw_failed=` + the pipeline line.
  void PrintSummary() const;

 private:
  void DrawOnRaster();  // one Consume (Rasterizer::Draw)
  void RasterAndPresent(std::unique_ptr<FrameItem> item);
  // Raster thread: an item retired without reaching the screen.
  void NoteLost(const FrameItem& item, const char* reason);
  // RNI_TEST_LOSE_FRAME_AFTER_IDLE_MS=ms[:count]: the first `count` items
  // drawn after the raster thread sat idle for >= ms are lost the way a nil
  // Metal drawable loses them (no draw, no present). Raster thread.
  bool TestLoseThis(const FrameItem& item);

  GlfwSurface& surface_;
  FrameTimings& timings_;
  FrameScheduler* scheduler_ = nullptr;
  ResizeSync* resizeSync_ = nullptr;
  Hooks hooks_;
  PlatformViewEmbedder* embedder_ = nullptr;
  PartialRepaint partial_;  // raster thread only
  bool partialRequested_ = true;
  std::atomic<bool> partialEnabled_{false};
  FramePipeline pipeline_;
  RasterThread raster_;
  bool started_ = false;
  bool shutdown_ = false;

  std::mutex mu_;  // guards the fields below
  std::condition_variable cv_;
  uint64_t submitted_ = 0;      // tickets handed out (main)
  int64_t readbackFrame_ = -1;  // frame number of the item that wants a readback
  bool grabOk_ = false;
  int grabW_ = 0, grabH_ = 0;
  std::vector<Px> grabPx_;
  int64_t delayFrame_ = -1;
  int delayMs_ = 0;

  std::atomic<int> presents_{0};
  std::atomic<uint64_t> retired_{0};
  std::atomic<uint64_t> drawFailed_{0};
  std::atomic<uint64_t> slotWaits_{0};
  std::atomic<uint64_t> presentedRevision_{0};
  std::atomic<uint64_t> lost_{0};
  std::atomic<int64_t> lastLostUs_{0};
  bool mutantMarkLost_ = false;
  bool mutantNoLostWake_ = false;
  int loseAfterIdleMs_ = 0;  // RNI_TEST_LOSE_FRAME_AFTER_IDLE_MS (raster thread)
  int loseCount_ = 1;
  int loseHoldMs_ = 0;
  int loseLeft_ = 0;
  int64_t lastRasterUs_ = 0;
  int everyFrameDelayMs_ = 0;  // RNI_TEST_RASTER_DELAY_MS
  bool log_ = false;           // RNI_TEST_RASTER_LOG=1
  bool availProbe_ = false;    // FP-31: RNI_TEST_GPU_AVAIL_PROBE=1
};

}  // namespace rni
