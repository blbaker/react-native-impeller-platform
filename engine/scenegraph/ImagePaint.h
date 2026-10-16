#pragma once

// A19 (SC-30): <Image> painting. Textures are uploaded once per decoded source
// (rni::image cache) and kept for the scene's lifetime.

#include "impeller.h"
#include "scenegraph/GpuBackend.h"
#include "scenegraph/RasterJobs.h"

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
  };
  std::unordered_map<const image::Decoded*, Entry> entries_;
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
