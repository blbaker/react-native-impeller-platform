#include "scenegraph/ColorMatrixFilter.h"

#include <algorithm>
#include <cmath>
#include <variant>

namespace rni {
namespace {

using Mat = std::array<float, 20>;
using facebook::react::FilterType;

constexpr Mat kIdentity = {1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0};

// Matrices from the CSS Filter Effects spec. Offsets are in 0..1.
Mat RgbMatrix(float a, float b, float c, float d, float e, float f, float g, float h, float i) {
  return {a, b, c, 0, 0, d, e, f, 0, 0, g, h, i, 0, 0, 0, 0, 0, 1, 0};
}

Mat Grayscale(float amount) {
  const float s = 1.0f - std::clamp(amount, 0.0f, 1.0f);
  return RgbMatrix(0.2126f + 0.7874f * s, 0.7152f - 0.7152f * s, 0.0722f - 0.0722f * s,
                   0.2126f - 0.2126f * s, 0.7152f + 0.2848f * s, 0.0722f - 0.0722f * s,
                   0.2126f - 0.2126f * s, 0.7152f - 0.7152f * s, 0.0722f + 0.9278f * s);
}

Mat Sepia(float amount) {
  const float s = 1.0f - std::clamp(amount, 0.0f, 1.0f);
  return RgbMatrix(0.393f + 0.607f * s, 0.769f - 0.769f * s, 0.189f - 0.189f * s,
                   0.349f - 0.349f * s, 0.686f + 0.314f * s, 0.168f - 0.168f * s,
                   0.272f - 0.272f * s, 0.534f - 0.534f * s, 0.131f + 0.869f * s);
}

Mat Saturate(float s) {
  s = std::max(s, 0.0f);
  return RgbMatrix(0.213f + 0.787f * s, 0.715f - 0.715f * s, 0.072f - 0.072f * s,
                   0.213f - 0.213f * s, 0.715f + 0.285f * s, 0.072f - 0.072f * s,
                   0.213f - 0.213f * s, 0.715f - 0.715f * s, 0.072f + 0.928f * s);
}

Mat HueRotate(float degrees) {
  const float r = degrees * 3.14159265358979f / 180.0f;
  const float c = std::cos(r), s = std::sin(r);
  return RgbMatrix(0.213f + c * 0.787f - s * 0.213f, 0.715f - c * 0.715f - s * 0.715f,
                   0.072f - c * 0.072f + s * 0.928f, 0.213f - c * 0.213f + s * 0.143f,
                   0.715f + c * 0.285f + s * 0.140f, 0.072f - c * 0.072f - s * 0.283f,
                   0.213f - c * 0.213f - s * 0.787f, 0.715f - c * 0.715f + s * 0.715f,
                   0.072f + c * 0.928f + s * 0.072f);
}

Mat Scale(float k, float offset) {
  Mat m = kIdentity;
  m[0] = m[6] = m[12] = k;
  m[4] = m[9] = m[14] = offset;
  return m;
}

bool ForFunction(const facebook::react::FilterFunction& f, Mat& m) {
  if (!std::holds_alternative<facebook::react::Float>(f.parameters)) return false;
  const float v = static_cast<float>(std::get<facebook::react::Float>(f.parameters));
  switch (f.type) {
    case FilterType::Brightness: m = Scale(std::max(v, 0.0f), 0.0f); return true;
    case FilterType::Contrast: m = Scale(std::max(v, 0.0f), 0.5f - 0.5f * std::max(v, 0.0f)); return true;
    case FilterType::Invert: {
      const float a = std::clamp(v, 0.0f, 1.0f);
      m = Scale(1.0f - 2.0f * a, a);
      return true;
    }
    case FilterType::Opacity: m = kIdentity; m[18] = std::clamp(v, 0.0f, 1.0f); return true;
    case FilterType::Grayscale: m = Grayscale(v); return true;
    case FilterType::Sepia: m = Sepia(v); return true;
    case FilterType::Saturate: m = Saturate(v); return true;
    case FilterType::HueRotate: m = HueRotate(v); return true;
    default: return false;
  }
}

// out = b applied after a (both 4x5 affine, the implied last row is 0 0 0 0 1).
Mat Then(const Mat& a, const Mat& b) {
  Mat o{};
  for (int r = 0; r < 4; ++r) {
    for (int c = 0; c < 5; ++c) {
      float v = (c == 4) ? b[r * 5 + 4] : 0.0f;
      for (int k = 0; k < 4; ++k) v += b[r * 5 + k] * a[k * 5 + c];
      o[r * 5 + c] = v;
    }
  }
  return o;
}

}  // namespace

bool BuildFilterMatrix(const std::vector<facebook::react::FilterFunction>& filters, Mat& out) {
  Mat total = kIdentity;
  bool any = false;
  for (const auto& f : filters) {
    Mat m;
    if (!ForFunction(f, m)) continue;
    total = Then(total, m);
    any = true;
  }
  if (any) out = total;
  return any;
}

ImpellerColorFilter MakeMatrixColorFilter(const Mat& m) {
  ImpellerColorMatrix cm;
  std::copy(m.begin(), m.end(), cm.m);
  return ImpellerColorFilterCreateColorMatrixNew(&cm);
}

}  // namespace rni
