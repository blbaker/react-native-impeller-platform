#include "scenegraph/ImageEvents.h"

#include <react/renderer/components/image/ImageEventEmitter.h>
#include <react/renderer/components/image/ImageShadowNode.h>
#include <react/renderer/imagemanager/ImageResponseObserver.h>
#include <react/renderer/imagemanager/ImageResponseObserverCoordinator.h>

#include "fabric/ImageStore.h"

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
      loaded.size = {(react::Float)d->width, (react::Float)d->height};
    }
    emitter_->onLoad(loaded);
    emitter_->onLoadEnd();
    sink_->fire();
  }

  void didReceiveFailure(const react::ImageLoadError& error) const override {
    react::ImageErrorInfo info;
    if (auto e = std::static_pointer_cast<const react::ImageErrorInfo>(error.getError())) info = *e;
    emitter_->onError(info);
    emitter_->onLoadEnd();
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
  emitter->onLoadStart();
  // Fires inline when the request already finished (local and cached sources).
  coordinator_->addObserver(observer_);
}

}  // namespace rni
