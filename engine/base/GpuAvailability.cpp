// FP-31: see GpuAvailability.h.
#include "base/GpuAvailability.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>

namespace rni::gpu {
namespace {

std::shared_mutex gSwitch;
bool gUnavailable = false;  // guarded by gSwitch
std::atomic<bool> gAvailable{true};
std::atomic<bool> gRestorePending{false};
std::atomic<int64_t> gRestoreUs{0};
std::atomic<bool> gAwaitRestorePresent{false};
std::atomic<uint64_t> gCounters[7];
std::atomic<uint64_t> gFlips{0};
std::mutex gListenerMu;
std::function<void()> gListener;

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

uint64_t C(Counter c) { return gCounters[(int)c].load(std::memory_order_relaxed); }

}  // namespace

Section::Section() : lock_(gSwitch), available_(!gUnavailable) {}

bool Available() { return gAvailable.load(std::memory_order_acquire); }

void Set(bool available, const char* reason) {
  {
    std::unique_lock<std::shared_mutex> lock(gSwitch);  // waits for GPU work in flight
    if (gUnavailable == !available) return;
    gUnavailable = !available;
    gAvailable.store(available, std::memory_order_release);
    gFlips.fetch_add(1, std::memory_order_relaxed);
    if (available) {
      gRestorePending.store(true, std::memory_order_release);
      gAwaitRestorePresent.store(true, std::memory_order_release);
      gRestoreUs.store(NowUs(), std::memory_order_release);
    }
    // Printed under the lock: the counters are exact at the flip.
    std::printf("rn-impeller: gpu_availability state=%s reason=%s t_us=%lld records=%llu "
                "draws=%llu presents=%llu uploads=%llu snapshots=%llu skipped_frames=%llu "
                "skipped_uploads=%llu\n",
                available ? "available" : "unavailable", reason, (long long)NowUs(),
                (unsigned long long)C(Counter::kRecord), (unsigned long long)C(Counter::kDraw),
                (unsigned long long)C(Counter::kPresent), (unsigned long long)C(Counter::kUpload),
                (unsigned long long)C(Counter::kSnapshot),
                (unsigned long long)C(Counter::kSkippedFrame),
                (unsigned long long)C(Counter::kSkippedUpload));
    std::fflush(stdout);
  }
  if (!available) return;
  std::function<void()> fn;
  {
    std::lock_guard<std::mutex> lock(gListenerMu);
    fn = gListener;
  }
  if (fn) fn();  // asks the scheduler for the repaint
}

void SetRestoreListener(std::function<void()> fn) {
  std::lock_guard<std::mutex> lock(gListenerMu);
  gListener = std::move(fn);
}

bool ConsumeRestore() { return gRestorePending.exchange(false, std::memory_order_acq_rel); }

void Note(Counter c) { gCounters[(int)c].fetch_add(1, std::memory_order_relaxed); }

int64_t LastRestoreUs() { return gRestoreUs.load(std::memory_order_acquire); }

void NotePresent(int presentNumber, bool fullRepaint) {
  if (!gAwaitRestorePresent.exchange(false, std::memory_order_acq_rel)) return;
  const int64_t now = NowUs();
  std::printf("rn-impeller: gpu_restore_present present=%d full=%d t_us=%lld since_restore_us=%lld\n",
              presentNumber, fullRepaint ? 1 : 0, (long long)now,
              (long long)(now - gRestoreUs.load(std::memory_order_acquire)));
  std::fflush(stdout);
}

void PrintSummary() {
  std::printf("rn-impeller: gpu_availability_summary flips=%llu records=%llu draws=%llu "
              "presents=%llu uploads=%llu snapshots=%llu skipped_frames=%llu skipped_uploads=%llu\n",
              (unsigned long long)gFlips.load(), (unsigned long long)C(Counter::kRecord),
              (unsigned long long)C(Counter::kDraw), (unsigned long long)C(Counter::kPresent),
              (unsigned long long)C(Counter::kUpload), (unsigned long long)C(Counter::kSnapshot),
              (unsigned long long)C(Counter::kSkippedFrame),
              (unsigned long long)C(Counter::kSkippedUpload));
}

}  // namespace rni::gpu
