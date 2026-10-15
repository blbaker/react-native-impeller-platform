// FP-16: fixed worker pool, see ImageIoPool.h.
#include "ImageIoPool.h"

#include <algorithm>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

#if defined(__linux__) || defined(__APPLE__)
#include <pthread.h>
#endif

#include "base/Trace.h"

namespace rni::image {

struct IoPool::State {
  std::mutex mutex;
  std::condition_variable cv;
  std::deque<std::function<void()>> queue;
  int started{0};
};

IoPool::IoPool(const char* osName, int threads)
    : state_(new State()), osName_(osName), threads_(std::max(1, threads)) {}

int IoPool::started() const {
  std::lock_guard<std::mutex> lock(state_->mutex);
  return state_->started;
}

void IoPool::Post(std::function<void()> task) {
  State* s = state_;
  bool spawn = false;
  {
    std::lock_guard<std::mutex> lock(s->mutex);
    s->queue.push_back(std::move(task));
    if (s->started == 0) {
      s->started = threads_;
      spawn = true;
    }
  }
  if (spawn) {
    for (int i = 0; i < threads_; ++i) {
      std::thread([s, name = osName_]() {
        rni::trace::SetThreadName("image-io");  // trace lane; it also renames the OS thread, so:
#if defined(__linux__)
        pthread_setname_np(pthread_self(), name);
#elif defined(__APPLE__)
        pthread_setname_np(name);
#endif
        for (;;) {
          std::function<void()> job;
          {
            std::unique_lock<std::mutex> lock(s->mutex);
            s->cv.wait(lock, [s] { return !s->queue.empty(); });
            job = std::move(s->queue.front());
            s->queue.pop_front();
          }
          job();
        }
      }).detach();
    }
  }
  s->cv.notify_one();
}

int DecodePoolSize() {
  const unsigned cores = std::thread::hardware_concurrency();
  return std::clamp((int)(cores / 2), 1, 4);
}

}  // namespace rni::image
