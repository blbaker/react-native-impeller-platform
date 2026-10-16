// FP-15: the windowed raster thread's task runner.
//
// Model: flutter/fml/message_loop + fml::TaskRunner as the shell uses them for
// its raster runner (shell/common/thread_host.cc makes one thread per runner;
// Shell::OnAnimatorDraw posts Rasterizer::Draw to it). One thread, FIFO tasks.
// `inline` mode is Flutter's merged platform/raster runner (the platform
// thread runs raster tasks itself): Post runs the task on the caller.
#pragma once

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>

namespace rni {

// A per-thread id for logs (gettid on linux), comparable across log lines.
long long CurrentThreadTag();

class RasterThread {
 public:
  using Task = std::function<void()>;

  // threaded=false: no thread; every task runs on the posting thread.
  explicit RasterThread(bool threaded);
  ~RasterThread();  // Join()
  RasterThread(const RasterThread&) = delete;
  RasterThread& operator=(const RasterThread&) = delete;

  bool threaded() const { return threaded_; }
  // FIFO. After Join() a task is dropped (counted).
  void Post(Task task);
  // Runs `task` on the raster thread and waits for it; inline when the caller
  // is already the raster thread (or in inline mode).
  void PostSync(const Task& task);
  bool IsCurrent() const;
  // Runs every task already queued, then stops the thread and joins it.
  void Join();

 private:
  void Loop();

  const bool threaded_;
  std::thread::id ownerId_;  // the raster thread (or the inline caller)
  std::mutex mu_;
  std::condition_variable cv_;
  std::deque<Task> queue_;
  bool stop_ = false;
  bool joined_ = false;
  std::thread thread_;
};

}  // namespace rni
