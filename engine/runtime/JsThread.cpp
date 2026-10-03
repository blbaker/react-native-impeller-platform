#include "runtime/JsThread.h"

#include <cstdio>
#include <future>

namespace rni {

namespace {
std::chrono::steady_clock::duration msToDuration(double delayMs) {
  if (delayMs < 0) delayMs = 0;
  return std::chrono::duration_cast<std::chrono::steady_clock::duration>(
      std::chrono::duration<double, std::milli>(delayMs));
}
}  // namespace

JsThread::JsThread() { thread_ = std::thread([this] { loop(); }); }

JsThread::~JsThread() {
  if (thread_.joinable()) {
    quitSynchronous();
  }
}

void JsThread::loop() {
  while (true) {
    std::function<void()> task;
    std::function<void(uint32_t)> fire;
    uint32_t fireId = 0;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      while (true) {
        // Explicit tasks beat timers on purpose: RuntimeScheduler drains
        // microtasks at the end of each task, so a task already queued in this
        // tick must run before the next timer deadline is serviced.
        if (!queue_.empty()) {
          task = std::move(queue_.front());
          queue_.pop_front();
          busy_ = true;
          break;
        }
        if (quit_) {
          return;  // quit_ set and queue drained
        }
        // Drop heap entries superseded or cancelled since being pushed.
        while (!timerHeap_.empty()) {
          const auto& top = timerHeap_.top();
          auto it = timers_.find(top.id);
          if (it == timers_.end() || it->second.seq != top.seq) {
            timerHeap_.pop();
          } else {
            break;
          }
        }
        if (timerHeap_.empty()) {
          cv_.wait(lock, [this] {
            return quit_ || !queue_.empty() || !timerHeap_.empty();
          });
          continue;
        }
        TimerEntry top = timerHeap_.top();
        auto now = std::chrono::steady_clock::now();
        if (top.deadline > now) {
          cv_.wait_until(lock, top.deadline);
          continue;
        }
        timerHeap_.pop();
        auto it = timers_.find(top.id);
        if (it->second.repeat) {
          top.deadline = now + it->second.interval;
          timerHeap_.push(top);
        } else {
          timers_.erase(it);
        }
        fire = timerFireCallback_;
        fireId = top.id;
        busy_ = true;
        break;
      }
    }
    if (task) {
      task();
      std::lock_guard<std::mutex> lock(mutex_);
      ++ran_;
    } else if (fire) {
      fire(fireId);
      std::lock_guard<std::mutex> lock(mutex_);
      ++timersFired_;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      busy_ = false;
    }
  }
}

void JsThread::runOnQueue(std::function<void()>&& task) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (quit_) return;
    queue_.push_back(std::move(task));
    ++enqueued_;
  }
  cv_.notify_one();
}

void JsThread::runOnQueueSync(std::function<void()>&& task) {
  if (std::this_thread::get_id() == thread_.get_id()) {
    task();
    return;
  }
  std::promise<void> done;
  auto future = done.get_future();
  runOnQueue([&task, &done] {
    task();
    done.set_value();
  });
  future.wait();
}

void JsThread::quitSynchronous() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    quit_ = true;
  }
  cv_.notify_one();
  if (thread_.joinable()) {
    thread_.join();
  }
}

void JsThread::setTimerFireCallback(std::function<void(uint32_t)> callback) {
  std::lock_guard<std::mutex> lock(mutex_);
  timerFireCallback_ = std::move(callback);
}

void JsThread::scheduleTimer(uint32_t id, double delayMs, bool repeat) {
  auto interval = msToDuration(delayMs);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (quit_) return;
    auto seq = ++timerSeq_;
    timers_[id] = TimerState{seq, repeat, interval};
    timerHeap_.push(
        TimerEntry{std::chrono::steady_clock::now() + interval, seq, id});
  }
  cv_.notify_one();
}

void JsThread::cancelTimer(uint32_t id) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    timers_.erase(id);  // heap entry dropped lazily in loop()
  }
  cv_.notify_one();
}

void JsThread::cancelAllTimers() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    timers_.clear();
    timerHeap_ = {};
  }
  cv_.notify_one();
}

bool JsThread::isIdle() {
  std::lock_guard<std::mutex> lock(mutex_);
  return queue_.empty() && timers_.empty() && !busy_;
}

size_t JsThread::pendingTasks() {
  std::lock_guard<std::mutex> lock(mutex_);
  return queue_.size();
}

std::string JsThread::debugStats() {
  std::lock_guard<std::mutex> lock(mutex_);
  char buf[256];
  std::snprintf(buf, sizeof(buf),
                "queue=%zu timers=%zu busy=%d enq=%llu ran=%llu fired=%llu",
                queue_.size(), timers_.size(), busy_ ? 1 : 0,
                (unsigned long long)enqueued_, (unsigned long long)ran_,
                (unsigned long long)timersFired_);
  return std::string(buf);
}

}  // namespace rni
