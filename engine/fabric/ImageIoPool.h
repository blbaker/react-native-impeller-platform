#pragma once

// FP-16: a fixed pool of worker threads (model: the engine's concurrent task
// runner that ImageDecoderImpeller decodes on, shell/common/thread_host +
// fml/concurrent_message_loop.cc). Workers start on the first Post and live
// for the process; the pool object is never destroyed.

#include <functional>

namespace rni::image {

class IoPool {
 public:
  // `osName` is the OS thread name (<= 15 chars), visible in /proc/<pid>/task/*/comm.
  IoPool(const char* osName, int threads);
  void Post(std::function<void()> task);
  int size() const { return threads_; }
  int started() const;

 private:
  struct State;
  State* state_;
  const char* osName_;
  int threads_;
};

// min(4, cores / 2), at least 1: the decode pool size.
int DecodePoolSize();

}  // namespace rni::image
