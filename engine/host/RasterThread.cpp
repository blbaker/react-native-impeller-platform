// FP-15: see RasterThread.h (model: fml::TaskRunner on the shell's raster thread).
#include "host/RasterThread.h"

#include "base/Trace.h"

#if defined(__linux__)
#include <sys/syscall.h>
#include <unistd.h>
#endif

namespace rni {

long long CurrentThreadTag() {
#if defined(__linux__)
  return (long long)syscall(SYS_gettid);
#else
  return (long long)(std::hash<std::thread::id>()(std::this_thread::get_id()) & 0x7fffffff);
#endif
}

RasterThread::RasterThread(bool threaded) : threaded_(threaded) {
  if (!threaded_) {
    ownerId_ = std::this_thread::get_id();
    return;
  }
  thread_ = std::thread([this] { Loop(); });
  std::lock_guard<std::mutex> lock(mu_);
  ownerId_ = thread_.get_id();
}

RasterThread::~RasterThread() { Join(); }

void RasterThread::Post(Task task) {
  if (!task) return;
  if (!threaded_) {
    task();
    return;
  }
  {
    std::lock_guard<std::mutex> lock(mu_);
    if (stop_) return;
    queue_.push_back(std::move(task));
  }
  cv_.notify_one();
}

void RasterThread::PostSync(const Task& task) {
  if (!task) return;
  if (!threaded_ || IsCurrent()) {
    task();
    return;
  }
  std::mutex doneMu;
  std::condition_variable doneCv;
  bool done = false;
  {
    std::lock_guard<std::mutex> lock(mu_);
    if (stop_) return;  // joined: nothing runs on the raster thread any more
  }
  Post([&] {
    task();
    std::lock_guard<std::mutex> lock(doneMu);
    done = true;
    doneCv.notify_one();
  });
  std::unique_lock<std::mutex> lock(doneMu);
  doneCv.wait(lock, [&] { return done; });
}

bool RasterThread::IsCurrent() const {
  return !threaded_ || std::this_thread::get_id() == ownerId_;
}

void RasterThread::Join() {
  if (!threaded_) return;
  {
    std::lock_guard<std::mutex> lock(mu_);
    if (joined_) return;
    joined_ = true;
    stop_ = true;
  }
  cv_.notify_one();
  if (thread_.joinable()) thread_.join();
}

void RasterThread::Loop() {
  rni::trace::SetThreadName("raster");
  for (;;) {
    Task task;
    {
      std::unique_lock<std::mutex> lock(mu_);
      cv_.wait(lock, [this] { return stop_ || !queue_.empty(); });
      if (queue_.empty()) return;  // stop_ and drained
      task = std::move(queue_.front());
      queue_.pop_front();
    }
    task();
  }
}

}  // namespace rni
