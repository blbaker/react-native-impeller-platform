// A19 (SC-30): the impeller ImageManager, replacing RN's cxx stub (which
// returns a request that never completes). Local sources (data:, file://,
// absolute paths) are decoded into rni::image's cache here, at commit time,
// so the painter only uploads pixels. SC-31: remote sources complete later,
// from rni::image's fetch worker; the mount layer observes the coordinator
// for load events.

#include "ImageManager.h"

#include <react/renderer/imagemanager/ImageRequest.h>
#include <react/renderer/imagemanager/primitives.h>

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
  ImageRequest request{imageSource, nullptr, {}};
  if (imageSource.uri.empty()) return request;
  auto coordinator = request.getSharedObserverCoordinator();
  rni::image::LoadAsync(
      imageSource.uri, imageSource.headers, [coordinator](const rni::image::LoadResult& r) {
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
      });
  return request;
}

}  // namespace facebook::react
