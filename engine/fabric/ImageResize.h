#pragma once

// FP-16: decode sizing and the CPU downscale (model: ResizeOnCpu and the
// target/max-texture clamp in DecompressTexture,
// engine/src/flutter/lib/ui/painting/image_decoder_impeller.cc L226-L272 and
// L347-L353). Flutter's resize is a bilinear scalePixels with no mipmaps; this
// is an exact area (box) filter, so large reductions do not alias.

#include <cstdint>
#include <vector>

namespace rni::image {

struct PixelSize {
  int width{0};
  int height{0};
};

// Smallest power of two >= px (0 stays 0 = unknown). The cache key uses it, so
// boxes of 129..256 px share one decode.
int SizeBucket(float px);

// The pixel size a decode produces: the source shrunk (never enlarged) until it
// still covers the bucketed box (cover-fit keeps aspect, so cover/contain/
// stretch all have enough pixels), then fitted inside maxTexture. A box of 0
// means unknown: only the max-texture clamp applies.
PixelSize DecodeSize(int srcW, int srcH, int boxW, int boxH, int maxTexture);

// Exact area-average downscale of premultiplied RGBA8 rows fed top to bottom.
// Holds two accumulator rows, never the source image.
class AreaDownscaler {
 public:
  AreaDownscaler(int srcW, int srcH, int dstW, int dstH, uint8_t* out);
  void Push(const uint8_t* rgbaRow);
  bool Done() const { return row_ >= dstH_; }

 private:
  void Emit();

  int srcW_, srcH_, dstW_, dstH_;
  uint8_t* out_;
  std::vector<int> colIdx_, rowIdx_;
  std::vector<float> colShare_, rowShare_, colSpill_, rowSpill_, colSum_, rowSum_;
  std::vector<float> h_, cur_, next_;
  int y_{0}, row_{0};
};

}  // namespace rni::image
