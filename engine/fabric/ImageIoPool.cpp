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

#include "base/MemTrim.h"
#include "base/Trace.h"

namespace rni::image {

struct IoPool::State {
  std::mutex mutex;
  std::condition_variable cv;
  std::deque<std::function<void()>> queue;
  int started{0};
  int running{0};  // jobs being run right now
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
            ++s->running;
          }
          job();
          job = nullptr;  // the job's captures (fetched bodies, decode buffers) go before the idle check
          bool idle = false;
          {
            std::lock_guard<std::mutex> lock(s->mutex);
            idle = --s->running == 0 && s->queue.empty();
          }
          // A burst of decodes (a screen of images) leaves its scratch buffers free in
          // this pool's arenas: hand those pages back once the burst is over.
          if (idle) rni::memtrim::Request("image_io");
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
