// FP-16: decode sizing + area downscale, see ImageResize.h.
#include "ImageResize.h"

#include <algorithm>
#include <cmath>

namespace rni::image {
namespace {

// For each source index i: the first destination index it lands in, the share
// of i inside it and the spill into idx + 1. Sums are per destination.
void Spans(int src, int dst, std::vector<int>& idx, std::vector<float>& share,
           std::vector<float>& spillOut, std::vector<float>& sum) {
  idx.assign(src, 0);
  share.assign(src, 1.0f);
  spillOut.assign(src, 0.0f);
  sum.assign(dst, 0.0f);
  const double s = (double)src / (double)dst;
  for (int i = 0; i < src; ++i) {
    const int o = std::min(dst - 1, (int)(i / s));
    const double edge = (o + 1) * s;
    const double a = (i + 1 <= edge || o + 1 >= dst) ? 1.0 : edge - i;
    const double spill = 1.0 - a;
    idx[i] = o;
    share[i] = (float)a;
    spillOut[i] = (float)spill;
    sum[o] += (float)a;
    if (spill > 0.0) sum[o + 1] += (float)spill;
  }
}

}  // namespace

int SizeBucket(float px) {
  if (!(px > 0.0f)) return 0;
  const float capped = std::min(px, (float)(1 << 24));
  int b = 1;
  while ((float)b < capped - 0.01f) b <<= 1;
  return b;
}

PixelSize DecodeSize(int srcW, int srcH, int boxW, int boxH, int maxTexture) {
  double w = srcW, h = srcH;
  if (boxW > 0 && boxH > 0) {
    const double s = std::min(1.0, std::max((double)boxW / srcW, (double)boxH / srcH));
    w = std::max(1.0, std::round(srcW * s));
    h = std::max(1.0, std::round(srcH * s));
  }
  if (maxTexture > 0 && (w > maxTexture || h > maxTexture)) {
    const double c = std::min(maxTexture / w, maxTexture / h);
    w = std::max(1.0, std::floor(w * c));
    h = std::max(1.0, std::floor(h * c));
  }
  return {(int)w, (int)h};
}

AreaDownscaler::AreaDownscaler(int srcW, int srcH, int dstW, int dstH, uint8_t* out)
    : srcW_(srcW), srcH_(srcH), dstW_(dstW), dstH_(dstH), out_(out) {
  Spans(srcW, dstW, colIdx_, colShare_, colSpill_, colSum_);
  Spans(srcH, dstH, rowIdx_, rowShare_, rowSpill_, rowSum_);
  h_.assign((size_t)dstW * 4, 0.0f);
  cur_.assign((size_t)dstW * 4, 0.0f);
  next_.assign((size_t)dstW * 4, 0.0f);
}

void AreaDownscaler::Push(const uint8_t* row) {
  if (y_ >= srcH_) return;
  std::fill(h_.begin(), h_.end(), 0.0f);
  for (int x = 0; x < srcW_; ++x) {
    const uint8_t* p = row + (size_t)x * 4;
    float* a = &h_[(size_t)colIdx_[x] * 4];
    const float wa = colShare_[x], wb = colSpill_[x];
    for (int c = 0; c < 4; ++c) a[c] += p[c] * wa;
    if (wb > 0.0f) {
      for (int c = 0; c < 4; ++c) a[4 + c] += p[c] * wb;
    }
  }
  const int o = rowIdx_[y_];
  while (row_ < o) Emit();
  const float wa = rowShare_[y_], wb = rowSpill_[y_];
  for (size_t i = 0; i < h_.size(); ++i) cur_[i] += h_[i] * wa;
  if (wb > 0.0f) {
    for (size_t i = 0; i < h_.size(); ++i) next_[i] += h_[i] * wb;
  }
  if (++y_ == srcH_) {
    while (row_ < dstH_) Emit();
  }
}

void AreaDownscaler::Emit() {
  if (row_ >= dstH_) return;
  uint8_t* dst = out_ + (size_t)row_ * dstW_ * 4;
  const float rs = rowSum_[row_];
  for (int x = 0; x < dstW_; ++x) {
    const float norm = colSum_[x] * rs;
    for (int c = 0; c < 4; ++c) {
      const float v = norm > 0.0f ? cur_[(size_t)x * 4 + c] / norm : 0.0f;
      dst[(size_t)x * 4 + c] = (uint8_t)std::clamp((int)std::lround(v), 0, 255);
    }
  }
  std::swap(cur_, next_);
  std::fill(next_.begin(), next_.end(), 0.0f);
  ++row_;
}

}  // namespace rni::image
