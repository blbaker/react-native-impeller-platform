// SC-31: the "ImageLoader" TurboModule (NativeImageLoaderIOSCxxSpec) behind
// Image.getSize / getSizeWithHeaders / prefetch / queryCache. It shares
// rni::image's in-memory cache with <Image>, so a prefetched URI paints
// without a second request.
#pragma once

#include <FBReactNativeSpecJSI.h>

#include <memory>
#include <string>

#include "modules/NetworkingModule.h"

namespace rni {

namespace jsi = facebook::jsi;

// Points rni::image's remote loads at performRequest (GET, 15 s timeout) and
// counts them in `activity`, so a headless run waits for images like fetch().
void InstallImageFetcher(std::shared_ptr<NetworkActivity> activity);

class ImageLoaderModule
    : public facebook::react::NativeImageLoaderIOSCxxSpec<ImageLoaderModule> {
 public:
  explicit ImageLoaderModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker)
      : NativeImageLoaderIOSCxxSpec(std::move(jsInvoker)) {}

  jsi::Object getConstants(jsi::Runtime& rt) { return jsi::Object(rt); }
  // Resolves [width, height] in pixels.
  jsi::Value getSize(jsi::Runtime& rt, jsi::String uri);
  // Resolves {width, height}; `headers` go on the request.
  jsi::Value getSizeWithHeaders(jsi::Runtime& rt, jsi::String uri, jsi::Object headers);
  jsi::Value prefetchImage(jsi::Runtime& rt, jsi::String uri);
  jsi::Value prefetchImageWithMetadata(jsi::Runtime& rt, jsi::String uri, jsi::String,
                                       double);
  // {uri: 'memory'} for every URI the cache holds.
  jsi::Value queryCache(jsi::Runtime& rt, jsi::Array uris);

 private:
  enum class Shape { Pair, Object, Bool };
  jsi::Value load(jsi::Runtime& rt, std::string uri, std::vector<std::pair<std::string, std::string>> headers,
                  Shape shape);
};

}  // namespace rni
