#pragma once

// FP-16: decode entry used by ImageStore's IO pool (and the fuzzers). The
// result is sized by DecodeSize(source, box, maxTexture) and downscaled on the
// CPU with an area filter before anyone uploads it.

#include <cstddef>
#include <cstdint>
#include <memory>

#include "ImageStore.h"

namespace rni::image {

// Null when the bytes are not a decodable PNG/JPEG/GIF/BMP. boxW/boxH are the
// bucketed target in pixels (0 = unknown).
std::shared_ptr<const Decoded> DecodeBytes(const uint8_t* data, size_t n, int boxW, int boxH,
                                           int maxTexture);

}  // namespace rni::image
