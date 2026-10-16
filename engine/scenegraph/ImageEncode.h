// FP-43: PNG / JPEG encoding of a snapshot (lib/ui/painting/image_encoding.cc
// EncodeImage: kPNG, kRawRGBA ...; view-shot adds jpg with a quality). CPU
// only, called on the snapshot encoder thread.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace rni {

// `rgba` is premultiplied RGBA8, row 0 = top. PNG un-premultiplies (straight
// alpha, like UIImagePNGRepresentation); JPEG has no alpha and keeps the
// premultiplied colour, i.e. the view over black (Bitmap.compress JPEG).
// quality in [0, 1]. False on an encoder failure.
bool EncodePng(const std::vector<uint8_t>& rgba, int w, int h, std::vector<uint8_t>* out);
bool EncodeJpeg(const std::vector<uint8_t>& rgba, int w, int h, double quality,
                std::vector<uint8_t>* out);
std::string Base64(const std::vector<uint8_t>& bytes);

}  // namespace rni
