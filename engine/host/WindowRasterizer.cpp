// FP-15: see WindowRasterizer.h (model: shell/common/rasterizer.cc + shell.cc).
#include "host/WindowRasterizer.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <memory>
#include <thread>

#include "base/GpuAvailability.h"
#include "base/Trace.h"
#include "host/FrameScheduler.h"
#include "host/FrameTimings.h"
#include "host/GlfwSurface.h"
#include "host/ResizeSync.h"

namespace rni {
namespace {

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

long long ThreadTag() { return CurrentThreadTag(); }

int EnvInt(const char* name, int lo, int hi) {
  const char* v = std::getenv(name);
  if (!v) return 0;
  const int n = std::atoi(v);
  return n < lo ? lo : (n > hi ? hi : n);
}

}  // namespace

WindowRasterizer::WindowRasterizer(GlfwSurface& surface, FrameTimings& timings,
                                   bool threaded)
    : surface_(surface),
      timings_(timings),
      pipeline_(PipelineDepthFor(/*platformIsRaster=*/!threaded)),
      raster_(threaded) {
  everyFrameDelayMs_ = EnvInt("RNI_TEST_RASTER_DELAY_MS", 0, 1000);
  const char* log = std::getenv("RNI_TEST_RASTER_LOG");
  log_ = log && std::strcmp(log, "1") == 0;
  const char* probe = std::getenv("RNI_TEST_GPU_AVAIL_PROBE");
  availProbe_ = probe && std::strcmp(probe, "1") == 0;
}

WindowRasterizer::~WindowRasterizer() { Shutdown(); }

bool WindowRasterizer::Start(std::string* error) {
  bool ok = false;
  const long long mainTid = ThreadTag();
  long long rasterTid = 0;
  raster_.PostSync([&] {
    ok = surface_.initGpu(raster_.threaded(), error);
    if (ok) partialEnabled_.store(partial_.Init(partialRequested_), std::memory_order_release);
    rasterTid = ThreadTag();
  });
  started_ = ok;
  std::printf("rn-impeller: raster_thread threaded=%d depth=%u main_tid=%lld "
              "raster_tid=%lld test_delay_ms=%d\n",
              raster_.threaded() ? 1 : 0, pipeline_.stats().depth, mainTid,
              rasterTid, everyFrameDelayMs_);
  std::fflush(stdout);
  return ok;
}

bool WindowRasterizer::WaitForSlot(int waitMs) {
  if (!raster_.threaded() || pipeline_.FreeSlots() > 0) return true;
  slotWaits_.fetch_add(1, std::memory_order_relaxed);
  TRACE_EVENT0("frame", "AwaitPipelineSlot");
  std::unique_lock<std::mutex> lock(mu_);
  return cv_.wait_for(lock, std::chrono::milliseconds(waitMs),
                      [&] { return pipeline_.FreeSlots() > 0; });
}

FramePipeline::ProducerContinuation WindowRasterizer::AcquireSlot(int waitMs) {
  auto slot = pipeline_.Produce();
  if (slot || !raster_.threaded() || waitMs <= 0) return slot;
  // Back-pressure (see WaitForSlot); a slot frees when the raster thread
  // finishes an item.
  const auto until =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(waitMs);
  std::unique_lock<std::mutex> lock(mu_);
  while (!(slot = pipeline_.Produce())) {
    if (cv_.wait_until(lock, until) == std::cv_status::timeout) {
      slot = pipeline_.Produce();
      break;
    }
  }
  return slot;
}

uint64_t WindowRasterizer::Submit(FramePipeline::ProducerContinuation slot,
                                  std::unique_ptr<FrameItem> item, bool readback) {
  if (!slot || !item) return 0;
  if (readback) {
    std::lock_guard<std::mutex> lock(mu_);
    readbackFrame_ = (int64_t)item->frameNumber;
    grabOk_ = false;
  }
  (void)slot.Complete(std::move(item));
  const uint64_t ticket = ++submitted_;
  raster_.Post([this] { DrawOnRaster(); });  // Shell::OnAnimatorDraw
  return ticket;
}

void WindowRasterizer::DrawOnRaster() {
  (void)pipeline_.Consume(
      [this](std::unique_ptr<FrameItem> item) { RasterAndPresent(std::move(item)); });
  {
    std::lock_guard<std::mutex> lock(mu_);  // pairs with AcquireSlot's wait
  }
  cv_.notify_all();
}

void WindowRasterizer::RasterAndPresent(std::unique_ptr<FrameItem> item) {
  int delay = everyFrameDelayMs_;
  bool readback = false;
  {
    std::lock_guard<std::mutex> lock(mu_);
    if (delayFrame_ >= 0 && (int64_t)item->frameNumber == delayFrame_) delay = delayMs_;
    readback = readbackFrame_ >= 0 && (int64_t)item->frameNumber == readbackFrame_;
  }
  if (delay > 0) std::this_thread::sleep_for(std::chrono::milliseconds(delay));
  if (resizeSync_) resizeSync_->MaybeHang(item->width, item->height);  // FP-30 test hook
  // FP-30 (rasterizer.cc DoDraw -> Shell::ShouldDiscardLayerTree): a frame
  // recorded for another size than the surface's current one never presents.
  // Retires an item that never reaches the screen: unrun jobs mark their
  // entries failed (dependents redo them), timings are discarded.
  auto retireDropped = [&] {
    if (item->jobs) item->jobs->AfterRaster();
    if (item->timings) timings_.Discard(std::move(item->timings));
    {
      std::lock_guard<std::mutex> lock(mu_);
      if (readback) readbackFrame_ = -1;
      retired_.fetch_add(1, std::memory_order_acq_rel);
    }
    cv_.notify_all();
  };
  if (resizeSync_ && resizeSync_->ShouldDiscard(item->width, item->height, item->frameNumber)) {
    retireDropped();
    return;
  }
  // FP-31 (rasterizer.cc DrawToSurfaces + SyncSwitch): everything below is GPU
  // work. While the GPU is unavailable (window iconified, app in background)
  // the frame is dropped like kGpuUnavailable: no draw, no upload, no present.
  gpu::Section gpuSection;
  if (!gpuSection.available()) {
    gpu::Note(gpu::Counter::kSkippedFrame);
    retireDropped();
    return;
  }
  // DrawToSurfaces acquires the frame at the layer tree's size.
  surface_.ensureGpuSize(item->width, item->height);
  FrameItem& frame = *item;
  const bool drawn = RasterFrame(frame, [&](ImpellerDisplayList dl) {
    gpu::Note(gpu::Counter::kDraw);
    // FP-18: through the root buffer (keeps the previous frame), else direct.
    if (partialEnabled_.load(std::memory_order_relaxed)) {
      return partial_.Draw(surface_.context(), frame);
    }
    return surface_.drawDisplayList(dl);
  });
  if (!drawn) drawFailed_.fetch_add(1, std::memory_order_relaxed);
  const int n = presents_.load(std::memory_order_relaxed) + 1;
  if (readback) {
    std::vector<Px> px;
    gpu::Note(gpu::Counter::kSnapshot);
    const bool ok = surface_.readPixels(&px);
    std::lock_guard<std::mutex> lock(mu_);
    grabPx_ = std::move(px);
    grabOk_ = ok;
    grabW_ = surface_.gpuWidth();
    grabH_ = surface_.gpuHeight();
  }
  if (availProbe_) {  // FP-31 test hook: the centre pixel of every frame about to be shown
    std::vector<Px> px;
    gpu::Note(gpu::Counter::kSnapshot);
    if (surface_.readPixels(&px) && !px.empty()) {
      const Px& c = px[(size_t)(surface_.gpuHeight() / 2) * surface_.gpuWidth() + surface_.gpuWidth() / 2];
      std::printf("rn-impeller: gpu_probe present=%d frame=%llu r=%d g=%d b=%d t_us=%lld\n", n,
                  (unsigned long long)item->frameNumber, (int)c.r, (int)c.g, (int)c.b,
                  (long long)NowUs());
      std::fflush(stdout);
    }
  }
  if (hooks_.beforePresent) hooks_.beforePresent(n);
  gpu::Note(gpu::Counter::kPresent);
  {
    TRACE_EVENT0("raster", "Present");
    if (scheduler_) scheduler_->WillPresent();
    if (scheduler_ && scheduler_->source() == FrameScheduler::Source::kDisplayLink) {
      // FP-27: log the frame when it is displayed (presentedTime), not here.
      auto handle = scheduler_->displayHandle();
      const int64_t tick = item->vsyncUs, target = item->targetUs;
      auto encode = std::make_shared<std::atomic<int64_t>>(0);
      surface_.presentReportingDisplay([handle, n, tick, target, encode](int64_t presentedUs) {
        std::lock_guard<std::mutex> lock(handle->mu);
        if (handle->scheduler) {
          handle->scheduler->DidDisplay(n, presentedUs, encode->load(), tick, target);
        }
      });
      encode->store(NowUs());
    } else {
      surface_.present();
    }
    if (scheduler_) scheduler_->DidPresent(n, item->vsyncUs);
  }
  TRACE_COUNTER("presents", n);
  // Counted at the present: refresh_paints and presents= come from here.
  presents_.store(n, std::memory_order_release);
  gpu::NotePresent(n, !item->damage.partial);
  if (resizeSync_) resizeSync_->DidPresent(item->width, item->height);  // performCommit
  if (log_) {
    std::printf("rn-impeller: raster_present n=%d frame=%llu t_us=%lld tid=%lld\n", n,
                (unsigned long long)item->frameNumber, (long long)NowUs(), ThreadTag());
    std::fflush(stdout);
  }
  if (hooks_.afterPresent) hooks_.afterPresent(n);
  if (item->timings) {
    item->timings->RecordPresent();
    timings_.Commit(std::move(item->timings));
  }
  {
    std::lock_guard<std::mutex> lock(mu_);
    if (readback) readbackFrame_ = -1;
    retired_.fetch_add(1, std::memory_order_acq_rel);
  }
  cv_.notify_all();
}

bool WindowRasterizer::WaitPresented(uint64_t ticket, int timeoutMs) {
  std::unique_lock<std::mutex> lock(mu_);
  return cv_.wait_for(lock, std::chrono::milliseconds(timeoutMs),
                      [&] { return retired() >= ticket; });
}

bool WindowRasterizer::TakeGrab(std::vector<Px>* px, int* w, int* h) {
  std::lock_guard<std::mutex> lock(mu_);
  if (!grabOk_) return false;
  *px = std::move(grabPx_);
  *w = grabW_;
  *h = grabH_;
  grabOk_ = false;
  return true;
}

void WindowRasterizer::DelayFrame(uint64_t frameNumber, int ms) {
  std::lock_guard<std::mutex> lock(mu_);
  delayFrame_ = (int64_t)frameNumber;
  delayMs_ = ms;
}

void WindowRasterizer::Shutdown() {
  if (shutdown_) return;
  shutdown_ = true;
  if (resizeSync_) resizeSync_->Shutdown();  // FP-30: frees a test-hung raster thread
  // OnPlatformViewDestroyed: the raster thread finishes what is queued and
  // tears the surface down itself, then the platform thread continues.
  raster_.Post([this] {
    while (pipeline_.Consume([this](std::unique_ptr<FrameItem> item) {
      RasterAndPresent(std::move(item));
    }) == PipelineConsumeResult::kMoreAvailable) {
    }
    if (started_) {
      partial_.PrintSummary();
      partial_.Release();  // FP-18: its GL objects die with the context
      surface_.releaseGpu();
    }
  });
  raster_.Join();
}

void WindowRasterizer::PrintSummary() const {
  std::printf("rn-impeller: raster_thread_summary threaded=%d presents=%d "
              "draw_failed=%llu slot_waits=%llu\n",
              raster_.threaded() ? 1 : 0, presents(),
              (unsigned long long)drawFailed_.load(),
              (unsigned long long)slotWaits_.load());
  PrintPipelineSummary(pipeline_);
}

}  // namespace rni
