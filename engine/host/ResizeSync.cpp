// FP-30: see ResizeSync.h (model: macOS ResizeSynchronizer.swift +
// shell.cc ShouldDiscardLayerTree).
#include "host/ResizeSync.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>

#include "base/TestSync.h"

namespace rni {
namespace {

int64_t Pack(int w, int h) { return ((int64_t)w << 32) | (int64_t)(uint32_t)h; }
int PackW(int64_t s) { return (int)(s >> 32); }
int PackH(int64_t s) { return (int)(uint32_t)(s & 0xffffffff); }

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

const char* Name(ResizeSync::Result r) {
  switch (r) {
    case ResizeSync::Result::kOk: return "ok";
    case ResizeSync::Result::kTimeout: return "timeout";
    case ResizeSync::Result::kNoFrameYet: return "no_frame_yet";
    case ResizeSync::Result::kShutdown: return "shutdown";
  }
  return "?";
}

}  // namespace

ResizeSync::ResizeSync() {
  const char* v = std::getenv("RNI_TEST_RASTER_HANG_AFTER_RESIZE");
  hangAfter_ = v ? std::atoi(v) : 0;
}

void ResizeSync::SetExpected(int w, int h) {
  expected_.store(Pack(w, h), std::memory_order_release);
}

bool ResizeSync::ShouldDiscard(int w, int h, uint64_t frameNumber) {
  const int64_t expected = expected_.load(std::memory_order_acquire);
  lastChecked_.store(expected, std::memory_order_relaxed);
  if (expected == 0 || expected == Pack(w, h)) return false;
  discarded_.fetch_add(1, std::memory_order_relaxed);
  std::printf("rn-impeller: frame_discarded reason=size frame=%llu item=%dx%d expected=%dx%d\n",
              (unsigned long long)frameNumber, w, h, PackW(expected), PackH(expected));
  std::fflush(stdout);
  return true;
}

void ResizeSync::DidPresent(int w, int h) {
  {
    std::lock_guard<std::mutex> lock(mu_);
    presented_.store(Pack(w, h), std::memory_order_release);
    didReceiveFrame_.store(true, std::memory_order_release);
  }
  cv_.notify_all();
}

ResizeSync::Result ResizeSync::BeginResize(int w, int h,
                                           const std::function<bool()>& produce,
                                           const std::function<void()>& pump) {
  const int n = ++resizes_;
  const int64_t target = Pack(w, h);
  if (hangAfter_ > 0 && n == hangAfter_) {
    std::lock_guard<std::mutex> lock(mu_);
    hangSize_ = target;
  }
  const int64_t start = NowUs();
  Result result = Result::kOk;
  int produced = 0;
  if (!didReceiveFrame_.load(std::memory_order_acquire)) {
    result = Result::kNoFrameYet;  // nothing on screen to keep in sync yet
  } else {
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::milliseconds(testsync::ScaledMs(1000));
    bool submitted = false;
    while (true) {
      if (presented_.load(std::memory_order_acquire) == target) break;
      if (shutdown_.load(std::memory_order_acquire)) {
        result = Result::kShutdown;
        break;
      }
      if (std::chrono::steady_clock::now() > deadline) {
        result = Result::kTimeout;
        break;
      }
      if (!submitted && produce) {
        submitted = produce();
        ++produced;
        continue;
      }
      if (pump) pump();
      std::unique_lock<std::mutex> lock(mu_);
      cv_.wait_for(lock, std::chrono::milliseconds(2), [&] {
        return presented_.load(std::memory_order_relaxed) == target ||
               shutdown_.load(std::memory_order_relaxed);
      });
    }
  }
  const int64_t waited = NowUs() - start;
  if (result == Result::kOk) ++ok_;
  if (result == Result::kTimeout) ++timeouts_;
  if (result == Result::kNoFrameYet) ++noFrameYet_;
  if (waited > maxWaitUs_) maxWaitUs_ = waited;
  std::printf("rn-impeller: resize_sync n=%d size=%dx%d result=%s waited_us=%lld produced=%d\n",
              n, w, h, Name(result), (long long)waited, produced);
  std::fflush(stdout);
  return result;
}

void ResizeSync::Shutdown() {
  {
    std::lock_guard<std::mutex> lock(mu_);
    shutdown_.store(true, std::memory_order_release);
  }
  cv_.notify_all();
}

void ResizeSync::MaybeHang(int w, int h) {
  std::unique_lock<std::mutex> lock(mu_);
  if (hung_ || hangSize_ == 0 || hangSize_ != Pack(w, h)) return;
  hung_ = true;
  std::printf("rn-impeller: raster_test_hang size=%dx%d\n", w, h);
  std::fflush(stdout);
  cv_.wait(lock, [&] { return shutdown_.load(std::memory_order_relaxed); });
}

void ResizeSync::LastChecked(int* w, int* h) const {
  const int64_t s = lastChecked_.load(std::memory_order_relaxed);
  *w = PackW(s);
  *h = PackH(s);
}

void ResizeSync::PrintSummary() const {
  std::printf("rn-impeller: resize_sync_summary resizes=%d ok=%d timeouts=%d no_frame_yet=%d "
              "max_wait_us=%lld discarded=%llu\n",
              resizes_, ok_, timeouts_, noFrameYet_, (long long)maxWaitUs_,
              (unsigned long long)discarded_.load());
  std::fflush(stdout);
}

}  // namespace rni
