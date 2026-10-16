#pragma once

// A19 (SC-30): <Image> painting. Textures are uploaded once per decoded source
// (rni::image cache) and kept for the scene's lifetime.

#include "impeller.h"
#include "scenegraph/GpuBackend.h"
#include "scenegraph/RasterJobs.h"

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <unordered_map>

namespace rni {

namespace image {
struct Decoded;
}

// The uploaded texture's pixel size and the source image's own size (the
// decode may be smaller, FP-16).
struct ImageTextureInfo {
  int texWidth{0}, texHeight{0};
  int srcWidth{0}, srcHeight{0};
};

class ImageTextures {
 public:
  ImageTextures() = default;
  ImageTextures(const ImageTextures&) = delete;
  ImageTextures& operator=(const ImageTextures&) = delete;
  ~ImageTextures();
  // FP-32: releases every texture; the decoded pixels stay in the image store.
  size_t Clear();

  // FP-33: releases the textures whose bitmap the budget or a low-memory purge evicted. Cheap
  // when nothing was evicted since the last call. Paint thread.
  // FP-56: a texture painted this frame or the last one outlives a BUDGET eviction (Flutter
  // image_cache.dart _liveImages: a live image is returned as "keepAlive", never reloaded);
  // a purge still drops it, as ImageCache.clear() drops _liveImages.
  void Sweep();
  // Once per painted frame, before the walk: ages the keep-alive set, then sweeps.
  void BeginFrame();
  // Runs (any thread) when a reload of an evicted source ends, so the scene repaints.
  void SetReloadWake(std::function<void()> wake) { reloadWake_ = std::move(wake); }

  // Null when the source is not decoded (yet) or no backend is wired.
  // boxW/boxH: the painted box in device pixels (picks the decode size).
  // FP-20: a miss goes through the backend's uploader (GL: a pool name filled
  // on the raster side, FP-14, so RECORD makes no GL call; Metal/Vulkan:
  // Impeller uploads in place). `jobs` is this frame's raster queue.
  ImpellerTexture Get(TextureUploader* uploader, RasterJobs* jobs, const std::string& uri,
                      float boxW, float boxH, ImageTextureInfo* info);

 private:
  struct Entry {
    TextureSlot slot;
    std::shared_ptr<const image::Decoded> decoded;
    std::string uri;
    uint64_t lastUse{0};  // frame_ of the last Get that returned it
  };
  void Release(std::unordered_map<const image::Decoded*, Entry>::iterator it);
  std::unordered_map<const image::Decoded*, Entry> entries_;
  std::unordered_map<std::string, const image::Decoded*> live_;  // uri -> its newest entry
  uint64_t sweptEpoch_{0};
  uint64_t frame_{0};
  int sweptPurges_{0};
  size_t keptAlive_{0};  // entries kept after their bitmap was evicted
  std::function<void()> reloadWake_;
};

// RN ImageResizeMode values: 0 cover, 1 contain, 2 stretch, 3 center,
// 4 repeat, 5 none. `scale` is the source's pixels per point (repeat/center/none
// use the image's natural size in points). `tint` (RGBA 0..1) replaces every
// opaque pixel's colour, keeping its alpha; null for no tint. The caller clips
// to the view's (rounded) box.
void PaintImage(ImpellerDisplayListBuilder builder, ImpellerTexture texture,
                const ImageTextureInfo& info, float scale, float x, float y, float w, float h,
                int resizeMode, const float* tint, float alpha);

}  // namespace rni
