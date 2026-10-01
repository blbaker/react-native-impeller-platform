// ClipboardBridge — thread-safe access to the system clipboard.
//
// ⛔ GLFW'S CLIPBOARD FUNCTIONS ARE MAIN-THREAD ONLY. glfwGetClipboardString
// and glfwSetClipboardString are ordinary GLFW calls, which this engine's own
// contract (every other glfw* call) restricts to the thread that owns the
// window -- the main/event thread the windowed frame loop runs on. The
// Clipboard TurboModule, by contrast, is called from the JS THREAD. Calling a
// GLFW function from the JS thread races GLFW's internal X11 state with
// whatever the main thread is doing inside glfwPollEvents/glfwWaitEventsTimeout
// at the same moment -- undefined behaviour, not merely "sometimes wrong".
//
// So every system-clipboard access is funnelled through a mutex-guarded FIFO
// of std::function<void()> tasks that the windowed frame loop drains once per
// iteration (main.cpp calls drainMain() right after applyResizeIfDirty()).
// FIFO order is load-bearing: ClipboardModule::setString posts a write before
// getString posts its read, so a JS-level `setString('x'); getString()`
// resolves 'x' no matter how the two tasks happen to be scheduled relative to
// frame boundaries.
//
// A plain queue a drained-once-per-frame loop would starve while the window
// is PARKED in glfwWaitEventsTimeout (the --idle-skip sleep): nothing wakes
// the loop just because the JS thread queued a clipboard request. So a
// SEPARATE wake callback (GlfwSurface::postEmptyEvent, which GLFW documents
// as callable from any thread) is posted alongside every queued task.
//
// With NO system backend installed -- the HEADLESS case, where no GLFW window
// and therefore no "main thread restriction" exists at all -- the bridge
// serves requests from a process-local string and runs them INLINE: there is
// nothing to protect against, and queuing for a drain that will never run
// (no windowed frame loop exists) would hang every headless Clipboard call
// forever.
#pragma once

#include <deque>
#include <functional>
#include <mutex>
#include <string>

namespace rni {

class ClipboardBridge {
 public:
  // Installs the REAL glfwGetClipboardString/glfwSetClipboardString pair.
  // Called exactly once by main.cpp's windowed path, after the GLFW window
  // exists. Never called in the headless path -- see the header comment on
  // why that is what makes headless requests run inline rather than queue.
  void setSystemBackend(std::function<std::string()> get,
                        std::function<void(const std::string&)> set) {
    std::lock_guard<std::mutex> lock(mutex_);
    systemGet_ = std::move(get);
    systemSet_ = std::move(set);
  }

  // The damage-wake callback (GlfwSurface::postEmptyEvent), so a frame loop
  // parked in glfwWaitEventsTimeout under --idle-skip notices a request the
  // JS thread just queued instead of waiting out the whole idle budget. Not
  // required for correctness (drainMain() still runs on the NEXT frame
  // regardless), only for latency; a bridge with no wake installed is safe,
  // just slower under --idle-skip.
  void setWake(std::function<void()> wake) {
    std::lock_guard<std::mutex> lock(mutex_);
    wake_ = std::move(wake);
  }

  // Runs every queued main-thread task, in FIFO order. Call once per
  // iteration of the windowed frame loop. Cheap when the queue is empty: one
  // lock + size check, no allocation.
  //
  // ⛔ EACH TASK RUNS OUTSIDE THE LOCK. A task that is slow (it is not, today
  // -- it is a string copy either way) or that itself called back into this
  // bridge would otherwise deadlock against the mutex drainMain is already
  // holding; running outside the lock is what makes that safe by
  // construction rather than by the current tasks happening not to do it.
  void drainMain() {
    for (;;) {
      std::function<void()> task;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (queue_.empty()) return;
        task = std::move(queue_.front());
        queue_.pop_front();
      }
      task();
    }
  }

  // Posts `task` to run on the main thread. With a system backend installed
  // (windowed), the task is queued for drainMain() and the wake (if any) is
  // fired. With NO system backend (headless), there is no main-thread
  // restriction to honour at all, so `task` runs INLINE, synchronously,
  // before this call returns -- see the header comment.
  void postToMain(std::function<void()> task) {
    std::function<void()> wake;
    bool haveBackend = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      haveBackend = (bool)systemGet_ || (bool)systemSet_;
      if (haveBackend) {
        queue_.push_back(std::move(task));
        wake = wake_;
      }
    }
    if (!haveBackend) {
      task();
      return;
    }
    if (wake) wake();
  }

  // Synchronous read, ALREADY ON THE MAIN THREAD (or headless, where every
  // thread qualifies). For two callers: a ClipboardModule::getString task
  // after postToMain has hopped it here, and FabricHost's Copy/Cut/Paste
  // keyboard shortcuts, which run on the main thread's GLFW key callback and
  // call this DIRECTLY -- see FabricHost.h's header on why those must never
  // go through postToMain's queue.
  std::string getSystemNow() {
    std::function<std::string()> get;
    std::string localCopy;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      get = systemGet_;
      localCopy = local_;
    }
    return get ? get() : localCopy;
  }

  // Synchronous write, same main-thread contract as getSystemNow().
  void setSystemNow(const std::string& s) {
    std::function<void(const std::string&)> set;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      set = systemSet_;
    }
    if (set) {
      set(s);
    } else {
      std::lock_guard<std::mutex> lock(mutex_);
      local_ = s;
    }
  }

 private:
  std::mutex mutex_;
  std::deque<std::function<void()>> queue_;
  std::function<std::string()> systemGet_;
  std::function<void(const std::string&)> systemSet_;
  std::function<void()> wake_;
  std::string local_;  // headless / no-backend fallback
};

}  // namespace rni
