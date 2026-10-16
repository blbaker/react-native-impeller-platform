#pragma once

// SC-31: <Image> load events. The mount layer observes each Image node's
// ImageRequest (RN's ImageState) and fires onLoadStart, then onLoad + onLoadEnd
// or onError + onLoadEnd through the node's ImageEventEmitter, as
// RCTImageComponentView does. A completed load also repaints.

#include <react/renderer/mounting/ShadowView.h>

#include <functional>
#include <memory>
#include <mutex>

namespace facebook::react {
class ImageResponseObserver;
class ImageResponseObserverCoordinator;
}  // namespace facebook::react

namespace rni {

// Repaint hook shared with fetch workers; the SceneGraph clears it on teardown.
struct ImageDamageSink {
  std::mutex mutex;
  std::function<void()> wake;
  void fire();
};

class ImageEventBinding {
 public:
  ImageEventBinding() = default;
  ImageEventBinding(const ImageEventBinding&) = delete;
  ImageEventBinding& operator=(const ImageEventBinding&) = delete;
  ~ImageEventBinding();

  // Observes the view's current request; a no-op while it is the one already observed.
  void update(const facebook::react::ShadowView& view, const std::shared_ptr<ImageDamageSink>& sink);

 private:
  void unbind();
  std::shared_ptr<const facebook::react::ImageResponseObserverCoordinator> coordinator_;
  std::shared_ptr<const facebook::react::ImageResponseObserver> observer_;
};

// FP-57 test probe (RNI_TEST_IMAGE_EVENT_STALL_MS; ImageEvents.cpp): quit lands while a
// JS-thread mount with an <Image> is in flight. Main arms it when the windowed loop starts
// and reports LoopExited / SurfaceStopping; the mount path calls BeforeMount (before the
// mount lock) and BeforeLoadStart.
namespace image_event_probe {
void Arm();
void LoopExited();
void SurfaceStopping();
void BeforeMount();
void BeforeLoadStart();
}  // namespace image_event_probe

}  // namespace rni
