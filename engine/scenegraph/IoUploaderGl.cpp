// FP-17: see IoUploader.h.
#include "scenegraph/IoUploader.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

#include "base/GpuAvailability.h"
#include "base/Trace.h"
#include "fabric/ImageStore.h"

#if defined(__linux__)
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

#if !defined(__ANDROID__)
#define RNI_IO_GL 1
#include "scenegraph/SceneGraphGl.h"  // last: gl* are macros on Windows
#else
#define RNI_IO_GL 0
#endif

namespace rni::io {
namespace {

struct Task {
  std::shared_ptr<const image::Decoded> d;
  std::function<void()> done;
};
struct Ready {
  std::weak_ptr<const image::Decoded> d;
  uint32_t name;
};

std::atomic<bool> gEnabled{true};
std::mutex gMu;
std::condition_variable gCv;
std::deque<Task> gQueue;
std::unordered_map<const image::Decoded*, Ready> gReady;  // finished, not taken yet
std::thread gThread;
bool gRunning = false, gStopping = false;
std::atomic<uint64_t> gUploads{0}, gTaken{0}, gFailed{0}, gMaxUs{0};

long long Tid() {
#if defined(__linux__)
  return (long long)syscall(SYS_gettid);
#else
  return (long long)(std::hash<std::thread::id>()(std::this_thread::get_id()) & 0x7fffffff);
#endif
}

int DelayMs() {
  static const int ms = [] {
    const char* v = std::getenv("RNI_TEST_IO_UPLOAD_DELAY_MS");
    return v ? std::atoi(v) : 0;
  }();
  return ms;
}

// The texture is ready: publish its name, then complete the load (cache
// insert, onLoad, repaint). Called once per uploaded image.
void HandOff(const Task& t, uint32_t name) {
  {
    std::lock_guard<std::mutex> lock(gMu);
    gReady[t.d.get()] = {t.d, name};
  }
  t.done();
}

#if RNI_IO_GL
// Deletes finished names whose image died before anyone took them.
void PurgeDead() {
  std::vector<GLuint> dead;
  {
    std::lock_guard<std::mutex> lock(gMu);
    for (auto it = gReady.begin(); it != gReady.end();) {
      if (it->second.d.expired()) {
        dead.push_back(it->second.name);
        it = gReady.erase(it);
      } else {
        ++it;
      }
    }
  }
  if (!dead.empty()) glDeleteTextures((GLsizei)dead.size(), dead.data());
}

// Upload, fence, wait, then hand off. False when nothing was handed off.
bool Upload(const Task& t) {
  TRACE_EVENT0("image", "IoUpload");
  const auto start = std::chrono::steady_clock::now();
  const image::Decoded& d = *t.d;
  GLuint name = 0;
  glGenTextures(1, &name);
  glBindTexture(GL_TEXTURE_2D, name);
  if (DelayMs() > 0) {
    // Test hook: a slow transfer. The storage holds poison (magenta) until the
    // pixels land, so a hand-off before the fence puts poison on screen
    // (ci-image-upload arm B).
    std::vector<uint8_t> poison((size_t)d.width * d.height * 4);
    for (size_t i = 0; i < poison.size(); i += 4) {
      poison[i] = 255, poison[i + 1] = 0, poison[i + 2] = 255, poison[i + 3] = 255;
    }
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, d.width, d.height, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                 poison.data());
    glFlush();
    std::this_thread::sleep_for(std::chrono::milliseconds(DelayMs()));
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, d.width, d.height, GL_RGBA, GL_UNSIGNED_BYTE,
                    d.rgba.data());
  } else {
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, d.width, d.height, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                 d.rgba.data());
  }
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glBindTexture(GL_TEXTURE_2D, 0);
  // Flutter's WaitUntilCompleted branch: the texture is complete before any
  // other context can see its name.
  GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
  const GLenum w = fence ? glClientWaitSync(fence, GL_SYNC_FLUSH_COMMANDS_BIT, 10000000000ull)
                         : GL_WAIT_FAILED;
  if (fence) glDeleteSync(fence);
  if (w != GL_ALREADY_SIGNALED && w != GL_CONDITION_SATISFIED) {
    glDeleteTextures(1, &name);
    return false;
  }
  const uint64_t us = (uint64_t)std::chrono::duration_cast<std::chrono::microseconds>(
                          std::chrono::steady_clock::now() - start)
                          .count();
  HandOff(t, name);
  for (uint64_t m = gMaxUs.load(); us > m && !gMaxUs.compare_exchange_weak(m, us);) {
  }
  static const bool log = std::getenv("RNI_IMAGE_LOG") != nullptr;
  if (log) {
    std::printf("rn-impeller: image_upload w=%d h=%d src=%dx%d thread=io tid=%lld us=%llu\n",
                d.width, d.height, d.srcWidth, d.srcHeight, Tid(), (unsigned long long)us);
  }
  return true;
}
#endif

int gStartState = 0;  // 0 starting, 1 bound, -1 bind failed

void Loop(ContextHooks hooks) {
  trace::SetThreadName("io");
#if defined(__linux__)
  // Flutter's IO thread is ThreadPriority::kBackground = nice 10
  // (shell/platform/android/android_shell_holder.cc); per-thread on Linux.
  setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), 10);
#endif
  const bool bound = RNI_IO_GL && hooks.bind && hooks.bind();
  {
    std::lock_guard<std::mutex> lock(gMu);
    gStartState = bound ? 1 : -1;
  }
  gCv.notify_all();
  if (!bound) return;
  for (;;) {
    Task t;
    bool stopping;
    {
      std::unique_lock<std::mutex> lock(gMu);
      gCv.wait(lock, [] { return gStopping || !gQueue.empty(); });
      if (gQueue.empty()) break;
      t = std::move(gQueue.front());
      gQueue.pop_front();
      stopping = gStopping;
    }
    if (stopping) {  // shutting down: complete the load, upload nothing
      t.done();
      continue;
    }
#if RNI_IO_GL
    // FP-31 (ShellIOManager + is_gpu_disabled_sync_switch_): no GPU upload while
    // the GPU is unavailable. The load completes without a texture and the
    // raster side uploads it on the first frame after the restore (Take() == 0).
    gpu::Section gpuSection;
    if (!gpuSection.available()) {
      gpu::Note(gpu::Counter::kSkippedUpload);
      t.done();
      continue;
    }
    gpu::Note(gpu::Counter::kUpload);
    if (Upload(t)) {
      gUploads.fetch_add(1);
    } else {
      gFailed.fetch_add(1);
      t.done();
    }
    PurgeDead();
#endif
  }
#if RNI_IO_GL
  std::vector<GLuint> left;
  {
    std::lock_guard<std::mutex> lock(gMu);
    for (auto& [p, r] : gReady) left.push_back(r.name);
    gReady.clear();
  }
  if (!left.empty()) glDeleteTextures((GLsizei)left.size(), left.data());
  glFinish();
#endif
  if (hooks.unbind) hooks.unbind();
}

void Post(std::shared_ptr<const image::Decoded> d, std::function<void()> done) {
  {
    std::lock_guard<std::mutex> lock(gMu);
    if (gRunning && !gStopping) {
      gQueue.push_back({std::move(d), std::move(done)});
      gCv.notify_all();
      return;
    }
  }
  done();  // raced with Stop: the raster path uploads it
}

}  // namespace

void SetEnabled(bool on) { gEnabled.store(on); }
bool Enabled() { return gEnabled.load(); }

bool Start(ContextHooks hooks) {
  if (!Enabled() || !RNI_IO_GL) return false;
  {
    std::lock_guard<std::mutex> lock(gMu);
    if (gRunning) return true;
    gStartState = 0;
    gStopping = false;
  }
  gThread = std::thread([hooks = std::move(hooks)] { Loop(hooks); });
  bool ok;
  {
    std::unique_lock<std::mutex> lock(gMu);
    gCv.wait(lock, [] { return gStartState != 0; });
    ok = gStartState == 1;
    gRunning = ok;
  }
  if (!ok) {
    gThread.join();
    return false;
  }
  image::SetUploadHook(&Post);
  return true;
}

void Stop() {
  {
    std::lock_guard<std::mutex> lock(gMu);
    if (!gRunning) return;
  }
  image::SetUploadHook(nullptr);
  {
    std::lock_guard<std::mutex> lock(gMu);
    gStopping = true;
  }
  gCv.notify_all();
  gThread.join();
  std::lock_guard<std::mutex> lock(gMu);
  gRunning = false;
}

uint32_t Take(const image::Decoded* d) {
  std::lock_guard<std::mutex> lock(gMu);
  auto it = gReady.find(d);
  if (it == gReady.end()) return 0;
  // The address could belong to a newer image if the old one died untaken.
  auto live = it->second.d.lock();
  const uint32_t name = live.get() == d ? it->second.name : 0;
  if (name == 0) return 0;
  gReady.erase(it);
  gTaken.fetch_add(1);
  return name;
}

void PrintStats() {
  bool running;
  {
    std::lock_guard<std::mutex> lock(gMu);
    running = gRunning;
  }
  std::printf("rn-impeller: io_upload enabled=%d running=%d uploads=%llu taken=%llu failed=%llu "
              "max_us=%llu delay_ms=%d\n",
              Enabled() ? 1 : 0, running ? 1 : 0, (unsigned long long)gUploads.load(),
              (unsigned long long)gTaken.load(), (unsigned long long)gFailed.load(),
              (unsigned long long)gMaxUs.load(), DelayMs());
}

}  // namespace rni::io
