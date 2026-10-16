// FP-15: see RasterThread.h (model: fml::TaskRunner on the shell's raster thread).
#include "host/RasterThread.h"

#include "base/Trace.h"

#include <cstdio>

#if defined(__linux__)
#include <sys/syscall.h>
#include <unistd.h>
#endif
#if defined(__APPLE__)
#include <pthread.h>
#include <sys/qos.h>
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

// FP-19: flutter/shell/platform/darwin/macos/framework/Source/FlutterEngine.mm SetThreadPriority
// (kRaster): sched priority 47 (the main thread's) + QOS_CLASS_USER_INTERACTIVE. Without it a loaded
// Mac preempts the raster thread for 8-50 ms between the vsync tick and the present (ci-vsync B).
// Linux/Windows embedders leave the raster thread at the default priority; so do we.
static void SetRasterThreadPriority() {
#if defined(__APPLE__)
  // QoS first: once pthread_setschedparam has run, the QoS call is refused (EPERM).
  const int qosRc = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  pthread_t self = pthread_self();
  qos_class_t qos = QOS_CLASS_UNSPECIFIED;
  int rel = 0;
  pthread_get_qos_class_np(self, &qos, &rel);
  sched_param param;
  int policy;
  if (!pthread_getschedparam(self, &policy, &param)) {
    param.sched_priority = 47;
    pthread_setschedparam(self, policy, &param);
  }
  int prio = pthread_getschedparam(self, &policy, &param) ? -1 : param.sched_priority;
  std::printf("rn-impeller: raster_thread_priority qos=%s qos_rc=%d sched_priority=%d\n",
              qos == QOS_CLASS_USER_INTERACTIVE ? "user_interactive" : "other", qosRc, prio);
  std::fflush(stdout);
#endif
}

void RasterThread::Loop() {
  rni::trace::SetThreadName("raster");
  SetRasterThreadPriority();
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
