#include "scenegraph/ImageEvents.h"

#include <react/renderer/components/image/ImageEventEmitter.h>
#include <react/renderer/components/image/ImageShadowNode.h>
#include <react/renderer/imagemanager/ImageResponseObserver.h>
#include <react/renderer/imagemanager/ImageResponseObserverCoordinator.h>

#include "base/TestSync.h"
#include "fabric/ImageStore.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>

#if defined(__linux__)
#include <sys/syscall.h>
#include <unistd.h>
#endif

namespace rni {

namespace react = facebook::react;

void ImageDamageSink::fire() {
  std::function<void()> w;
  {
    std::lock_guard<std::mutex> lock(mutex);
    w = wake;
  }
  if (w) w();
}

namespace {

// FP-57: EventEmitter::dispatchEvent copies eventTarget_, which ShadowTree::tryCommit resets
// (setMounted -> setEnabled(false)) under EventEmitter::DispatchMutex() on whichever thread
// commits; RN documents that mutex as the guard (EventEmitter.h, EventTarget.h). Every image
// event dispatch takes it: the mount-thread onLoadStart and the IO-thread completions.
// dispatchEvent only enqueues (EventQueue mutex, async beat), so it never re-enters the lock.
template <typename F>
void Dispatch(F&& dispatch) {
  std::lock_guard<std::mutex> lock(react::EventEmitter::DispatchMutex());
  dispatch();
}

class LoadObserver final : public react::ImageResponseObserver {
 public:
  LoadObserver(std::shared_ptr<const react::ImageEventEmitter> emitter, react::ImageSource source,
               std::shared_ptr<ImageDamageSink> sink)
      : emitter_(std::move(emitter)), source_(std::move(source)), sink_(std::move(sink)) {}

  void didReceiveProgress(float, int64_t, int64_t) const override {}

  void didReceiveImage(const react::ImageResponse& response) const override {
    // onLoad reports the decoded pixel size (RN multiplies size by scale).
    react::ImageSource loaded = source_;
    loaded.scale = 1;
    if (auto d = std::static_pointer_cast<const image::Decoded>(response.getImage())) {
      // FP-16: the source size, not the (box-sized) decode
      loaded.size = {(react::Float)d->srcWidth, (react::Float)d->srcHeight};
    }
    Dispatch([&] {
      emitter_->onLoad(loaded);
      emitter_->onLoadEnd();
    });
    sink_->fire();
  }

  void didReceiveFailure(const react::ImageLoadError& error) const override {
    react::ImageErrorInfo info;
    if (auto e = std::static_pointer_cast<const react::ImageErrorInfo>(error.getError())) info = *e;
    Dispatch([&] {
      emitter_->onError(info);
      emitter_->onLoadEnd();
    });
    sink_->fire();
  }

 private:
  std::shared_ptr<const react::ImageEventEmitter> emitter_;
  react::ImageSource source_;
  std::shared_ptr<ImageDamageSink> sink_;
};

}  // namespace

ImageEventBinding::~ImageEventBinding() { unbind(); }

void ImageEventBinding::unbind() {
  if (coordinator_ && observer_) coordinator_->removeObserver(observer_);
  coordinator_.reset();
  observer_.reset();
}

void ImageEventBinding::update(const react::ShadowView& view,
                               const std::shared_ptr<ImageDamageSink>& sink) {
  auto state = std::dynamic_pointer_cast<const react::ImageShadowNode::ConcreteState>(view.state);
  auto emitter = std::dynamic_pointer_cast<const react::ImageEventEmitter>(view.eventEmitter);
  if (!state || !emitter) return;
  const react::ImageRequest& request = state->getData().getImageRequest();
  const auto& coordinator = request.getSharedObserverCoordinator();
  if (!coordinator || coordinator == coordinator_) return;
  unbind();
  // The initial state carries an empty request that never completes.
  if (request.getImageSource().uri.empty()) return;
  coordinator_ = coordinator;
  observer_ = std::make_shared<LoadObserver>(emitter, request.getImageSource(), sink);
  image_event_probe::BeforeLoadStart();
  Dispatch([&] { emitter->onLoadStart(); });
  // Fires inline when the request already finished (local and cached sources).
  coordinator_->addObserver(observer_);
}

namespace image_event_probe {
namespace {
// FP-57 probe (RNI_TEST_IMAGE_EVENT_STALL_MS=N, gates only), the quit-mid-mount window:
//   1 BeforeMount: the first JS-thread mount after the windowed loop started (Arm) asks the
//     loop to quit and waits, holding no lock, until main has left the loop (LoopExited);
//   2 it then pulls and applies the transaction as usual; its first onLoadStart parks until
//     FabricHost::stopSurface started the empty-tree commit (SurfaceHandler::stop ->
//     EventEmitter::setEnabled(false)), then dispatches.
// Relaxed atomics on purpose: the probe must not add the happens-before edge the fix provides.
std::atomic<bool> gArmed{false};
std::atomic<bool> gQuitting{false};
std::atomic<bool> gLoopExited{false};
std::atomic<bool> gParked{false};
std::atomic<bool> gSurfaceStopped{false};

int StallMs() {
  static const int ms = [] {
    const char* v = std::getenv("RNI_TEST_IMAGE_EVENT_STALL_MS");
    return v ? std::atoi(v) : 0;
  }();
  return ms;
}

bool OnMainThread() {
#if defined(__linux__)
  return syscall(SYS_gettid) == getpid();
#else
  return true;  // linux-only probe
#endif
}

void WaitFor(const std::atomic<bool>& flag, int ms) {
  for (int waited = 0; waited < ms && !flag.load(std::memory_order_relaxed); waited += 5) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
}
}  // namespace

void Arm() { gArmed.store(true, std::memory_order_relaxed); }
void LoopExited() { gLoopExited.store(true, std::memory_order_relaxed); }
void SurfaceStopping() { gSurfaceStopped.store(true, std::memory_order_relaxed); }

void BeforeMount() {
  const int ms = StallMs();
  if (ms <= 0 || !gArmed.load(std::memory_order_relaxed) || OnMainThread()) return;
  if (gQuitting.exchange(true, std::memory_order_relaxed)) return;
  testsync::RequestQuit();
  WaitFor(gLoopExited, ms);
  std::printf("rn-impeller: image_event_probe mount_after_quit loop_exited=%d\n",
              gLoopExited.load(std::memory_order_relaxed) ? 1 : 0);
  std::fflush(stdout);
}

void BeforeLoadStart() {
  const int ms = StallMs();
  if (ms <= 0 || !gQuitting.load(std::memory_order_relaxed) || OnMainThread()) return;
  if (gParked.exchange(true, std::memory_order_relaxed)) return;
  std::printf("rn-impeller: image_event_probe parked ms=%d\n", ms);
  std::fflush(stdout);
  WaitFor(gSurfaceStopped, ms);
  // SurfaceStopping fires right before SurfaceHandler::stop; its empty-tree commit runs
  // updateMountedFlag in well under this margin, then blocks in the synchronous mount on the
  // mount lock this thread holds.
  std::this_thread::sleep_for(std::chrono::milliseconds(testsync::ScaledMs(250)));
  std::printf("rn-impeller: image_event_probe resumed surface_stopped=%d\n",
              gSurfaceStopped.load(std::memory_order_relaxed) ? 1 : 0);
  std::fflush(stdout);
}

}  // namespace image_event_probe

}  // namespace rni
