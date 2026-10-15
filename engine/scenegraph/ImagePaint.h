#pragma once

// A19 (SC-30): <Image> painting. Textures are uploaded once per decoded source
// (rni::image cache) and kept for the scene's lifetime.

#include "impeller.h"

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

  // FP-33: releases the textures whose bitmap the budget or a low-memory purge evicted. Cheap
  // when nothing was evicted since the last call. Paint thread.
  void Sweep();
  // Runs (any thread) when a reload of an evicted source ends, so the scene repaints.
  void SetReloadWake(std::function<void()> wake) { reloadWake_ = std::move(wake); }

  // Null when the source is not decoded (yet) or no context is wired.
  // boxW/boxH: the painted box in device pixels (picks the decode size).
  ImpellerTexture Get(ImpellerContext context, const std::string& uri, float boxW, float boxH,
                      ImageTextureInfo* info);

 private:
  struct Entry {
    ImpellerTexture texture{nullptr};
    std::shared_ptr<const image::Decoded> decoded;
  };
  std::unordered_map<const image::Decoded*, Entry> entries_;
  uint64_t sweptEpoch_{0};
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
