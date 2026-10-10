#pragma once

// A19 (SC-30): <Image> painting. Textures are uploaded once per decoded source
// (rni::image cache) and kept for the scene's lifetime.

#include "impeller.h"

#include <memory>
#include <string>
#include <unordered_map>

namespace rni {

namespace image {
struct Decoded;
}

class ImageTextures {
 public:
  ImageTextures() = default;
  ImageTextures(const ImageTextures&) = delete;
  ImageTextures& operator=(const ImageTextures&) = delete;
  ~ImageTextures();

  // Null when the source did not decode or no context is wired.
  ImpellerTexture Get(ImpellerContext context, const std::string& uri, int* outW, int* outH);

 private:
  struct Entry {
    ImpellerTexture texture{nullptr};
    int width{0};
    int height{0};
  };
  std::unordered_map<std::string, Entry> entries_;
};

// RN ImageResizeMode values: 0 cover, 1 contain, 2 stretch, 3 center,
// 4 repeat, 5 none. `scale` is the source's pixels per point (repeat/center/none
// use the image's natural size in points). `tint` (RGBA 0..1) replaces every
// opaque pixel's colour, keeping its alpha; null for no tint. The caller clips
// to the view's (rounded) box.
void PaintImage(ImpellerDisplayListBuilder builder, ImpellerTexture texture, int texW,
                int texH, float scale, float x, float y, float w, float h, int resizeMode,
                const float* tint, float alpha);

}  // namespace rni
