// FP-52: the <Image> decode entry every ImageStore IO-pool job runs (local and
// remote bytes alike). Model: Skia fuzz/oss_fuzz/FuzzImage.cpp (decode, then use
// the pixels), with our box/max-texture inputs drawn from the data.
#include <fuzzer/FuzzedDataProvider.h>

#include <cstdlib>
#include <vector>

#include "fabric/ImageDecode.h"
#include "fuzz/Fuzz.h"

namespace rni::fuzz {

int ImageDecode(const uint8_t* data, size_t size) {
  if (size > 64 * 1024) return 0;
  FuzzedDataProvider in(data, size);
  constexpr int kMaxTextures[] = {64, 1024, 8192, 16384};
  const int boxW = in.ConsumeIntegralInRange<int>(0, 2048);
  const int boxH = in.ConsumeIntegralInRange<int>(0, 2048);
  const int maxTexture = in.PickValueInArray(kMaxTextures);
  // A heap copy of exactly the encoded bytes, so an over-read is an ASan report.
  const std::vector<uint8_t> bytes = in.ConsumeRemainingBytes<uint8_t>();
  auto d = image::DecodeBytes(bytes.data(), bytes.size(), boxW, boxH, maxTexture);
  if (!d) return 0;
  // What the uploader relies on (ImageTextures::Get, ImagePaint).
  if (d->width <= 0 || d->height <= 0 || d->width > maxTexture || d->height > maxTexture ||
      d->width > d->srcWidth || d->height > d->srcHeight ||
      d->rgba.size() != (size_t)d->width * (size_t)d->height * 4) {
    std::abort();
  }
  for (size_t i = 0; i < d->rgba.size(); i += 4) {  // premultiplied
    const uint8_t a = d->rgba[i + 3];
    if (d->rgba[i] > a || d->rgba[i + 1] > a || d->rgba[i + 2] > a) std::abort();
  }
  return 0;
}

}  // namespace rni::fuzz
