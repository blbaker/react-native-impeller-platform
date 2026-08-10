// JsThread — the JS thread. std::thread + FIFO queue implementing
// facebook::react::MessageQueueThread, so ReactInstance and RuntimeScheduler
// can dispatch onto it, plus a deadline min-heap so setTimeout/setInterval fire
// HERE and never on the platform thread.
//
// One thread owns the Hermes runtime for its whole life. Everything that
// touches jsi::Runtime arrives through runOnQueue.
#pragma once

#include <cxxreact/MessageQueueThread.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace rni {

class JsThread : public facebook::react::MessageQueueThread {
 public:
  JsThread();
  ~JsThread() override;

  void runOnQueue(std::function<void()>&& task) override;
  // Blocks until the task ran on the JS thread. Called FROM the JS thread it
  // runs inline, because blocking on ourselves is a deadlock, not a wait.
  void runOnQueueSync(std::function<void()>&& task) override;
  void quitSynchronous() override;

  // --- timers --------------------------------------------------------------
  // Set once at boot, before any bundle runs; invoked on the JS thread.
  void setTimerFireCallback(std::function<void(uint32_t)> callback);
  // Safe from any thread. Re-registering an id supersedes its deadline.
  void scheduleTimer(uint32_t id, double delayMs, bool repeat);
  void cancelTimer(uint32_t id);
  void cancelAllTimers();

  // No queued task, no live timer, nothing mid-execution. Used to drain async
  // JS work before teardown instead of guessing with a sleep.
  bool isIdle();

  // Snapshot of queue/timer/busy state + lifetime counters, safe from any
  // thread. `enq` climbing while `ran` is frozen means the JS thread is stuck
  // INSIDE a task; both frozen means nothing is enqueueing. These two look
  // identical from the outside ("the app froze") and have opposite causes.
  std::string debugStats();

 private:
  void loop();

  struct TimerEntry {
    std::chrono::steady_clock::time_point deadline;
    uint64_t seq;  // generation — stale heap entries are dropped lazily
    uint32_t id;
  };
  struct TimerEntryLater {
    bool operator()(const TimerEntry& a, const TimerEntry& b) const {
      return a.deadline != b.deadline ? a.deadline > b.deadline : a.seq > b.seq;
    }
  };
  struct TimerState {
    uint64_t seq;
    bool repeat;
    std::chrono::steady_clock::duration interval;
  };

  std::thread thread_;
  std::mutex mutex_;
  std::condition_variable cv_;
  std::deque<std::function<void()>> queue_;
  bool quit_{false};
  bool busy_{false};

  uint64_t enqueued_{0};
  uint64_t ran_{0};
  uint64_t timersFired_{0};

  std::priority_queue<TimerEntry, std::vector<TimerEntry>, TimerEntryLater>
      timerHeap_;
  std::unordered_map<uint32_t, TimerState> timers_;
  uint64_t timerSeq_{0};
  std::function<void(uint32_t)> timerFireCallback_;
};

}  // namespace rni
