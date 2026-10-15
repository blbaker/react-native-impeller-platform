// A19 (SC-30): the impeller ImageManager, replacing RN's cxx stub (which
// returns a request that never completes). FP-16: every source (local or
// remote) is decoded on rni::image's IO pool at the laid-out box size and
// completes from there; the mount layer observes the coordinator for load
// events, and the painter only uploads pixels.

#include "ImageManager.h"

#include <react/renderer/imagemanager/ImageRequest.h>
#include <react/renderer/imagemanager/primitives.h>

#include <atomic>
#include <memory>

#include "ImageStore.h"

namespace facebook::react {

ImageManager::ImageManager(const std::shared_ptr<const ContextContainer>& /*contextContainer*/) {
  (void)self_;
}

ImageManager::~ImageManager() = default;

ImageRequest ImageManager::requestImage(const ImageSource& imageSource,
                                        SurfaceId /*surfaceId*/,
                                        const ImageRequestParams& /*imageRequestParams*/,
                                        Tag /*tag*/) const {
  if (imageSource.uri.empty()) return ImageRequest{imageSource, nullptr, {}};
  // FP-16: RN's coordinator calls the cancelation function when the last
  // observer leaves while loading (the <Image> unmounted); the decode is then
  // skipped if nobody else waits for it. The ticket is only known after
  // LoadAsync, so the function reads it through a shared slot.
  auto ticket = std::make_shared<std::atomic<uint64_t>>(0);
  ImageRequest request{imageSource, nullptr, {},
                       SharedFunction<>([ticket] { rni::image::Cancel(ticket->load()); })};
  const auto& coordinator = request.getSharedObserverCoordinator();
  std::weak_ptr<const ImageResponseObserverCoordinator> weak = coordinator;
  // The decode targets the laid-out box: ImageShadowNode::getImageSource puts
  // the content frame in `size` and pointScaleFactor in `scale`.
  const float scale = imageSource.scale > 0 ? (float)imageSource.scale : 1.0f;
  ticket->store(rni::image::LoadAsync(
      imageSource.uri, imageSource.headers, (float)imageSource.size.width * scale,
      (float)imageSource.size.height * scale,
      [weak](const rni::image::LoadResult& r) {
        auto coordinator = weak.lock();
        if (!coordinator) return;
        if (r.image) {
          coordinator->nativeImageResponseComplete(
              ImageResponse(std::const_pointer_cast<rni::image::Decoded>(r.image), nullptr));
          return;
        }
        auto info = std::make_shared<ImageErrorInfo>();
        info->error = r.error;
        info->responseCode = r.status;
        info->httpResponseHeaders = r.headers;
        coordinator->nativeImageResponseFailed(ImageLoadError(info));
      },
      coordinator));
  return request;
}

}  // namespace facebook::react
