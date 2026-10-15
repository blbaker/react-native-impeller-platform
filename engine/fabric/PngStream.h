#pragma once

// FP-16: row-at-a-time PNG decoding. Scanlines come out of a streaming inflate
// and are handed over one by one as premultiplied RGBA8, so downscaling an
// 8000x6000 PNG never holds the full-size bitmap (stb_image inflates the whole
// image first). Non-interlaced PNGs of every colour type and bit depth;
// interlaced and Apple CgBI files return false and the caller uses stb_image.

#include <cstddef>
#include <cstdint>
#include <functional>

namespace rni::image {

using RowSink = std::function<void(const uint8_t* rgba, int y)>;

// False when this is not a PNG this path decodes or the data is corrupt; rows
// may already have been delivered then.
bool PngDecodeRows(const uint8_t* data, size_t n, const RowSink& sink);

}  // namespace rni::image
