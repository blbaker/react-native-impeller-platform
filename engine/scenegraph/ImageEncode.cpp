// FP-43: see ImageEncode.h.
#include "scenegraph/ImageEncode.h"

#include <algorithm>
#include <cmath>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STB_IMAGE_WRITE_STATIC
#define STBI_WRITE_NO_STDIO
#include "third_party/stb/stb_image_write.h"

namespace rni {
namespace {

void Append(void* ctx, void* data, int size) {
  auto* out = static_cast<std::vector<uint8_t>*>(ctx);
  const auto* p = static_cast<const uint8_t*>(data);
  out->insert(out->end(), p, p + size);
}

}  // namespace

bool EncodePng(const std::vector<uint8_t>& rgba, int w, int h, std::vector<uint8_t>* out) {
  if (w <= 0 || h <= 0 || rgba.size() != (size_t)w * h * 4) return false;
  std::vector<uint8_t> straight(rgba);
  for (size_t i = 0; i < straight.size(); i += 4) {
    const int a = straight[i + 3];
    if (a == 0 || a == 255) continue;
    for (int c = 0; c < 3; ++c) {
      straight[i + c] = (uint8_t)std::min(255, (straight[i + c] * 255 + a / 2) / a);
    }
  }
  out->clear();
  return stbi_write_png_to_func(Append, out, w, h, 4, straight.data(), w * 4) != 0 &&
         !out->empty();
}

bool EncodeJpeg(const std::vector<uint8_t>& rgba, int w, int h, double quality,
                std::vector<uint8_t>* out) {
  if (w <= 0 || h <= 0 || rgba.size() != (size_t)w * h * 4) return false;
  std::vector<uint8_t> rgb((size_t)w * h * 3);
  for (size_t i = 0, j = 0; i < rgba.size(); i += 4, j += 3) {
    rgb[j] = rgba[i];
    rgb[j + 1] = rgba[i + 1];
    rgb[j + 2] = rgba[i + 2];
  }
  const int q = std::max(1, std::min(100, (int)std::lround(quality * 100.0)));
  out->clear();
  return stbi_write_jpg_to_func(Append, out, w, h, 3, rgb.data(), q) != 0 && !out->empty();
}

std::string Base64(const std::vector<uint8_t>& b) {
  static const char* kT = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string s;
  s.reserve((b.size() + 2) / 3 * 4);
  size_t i = 0;
  for (; i + 2 < b.size(); i += 3) {
    const uint32_t v = (b[i] << 16) | (b[i + 1] << 8) | b[i + 2];
    s += kT[v >> 18];
    s += kT[(v >> 12) & 63];
    s += kT[(v >> 6) & 63];
    s += kT[v & 63];
  }
  if (i < b.size()) {
    const uint32_t v = (b[i] << 16) | (i + 1 < b.size() ? b[i + 1] << 8 : 0);
    s += kT[v >> 18];
    s += kT[(v >> 12) & 63];
    s += i + 1 < b.size() ? kT[(v >> 6) & 63] : '=';
    s += '=';
  }
  return s;
}

}  // namespace rni
