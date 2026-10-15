// FP-16: streaming PNG rows, see PngStream.h.
#include "PngStream.h"

#include <algorithm>
#include <cstring>
#include <utility>
#include <vector>

#include "Inflate.h"

namespace rni::image {
namespace {

uint32_t Be32(const uint8_t* p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

struct Png {
  int w{0}, h{0}, depth{0}, ctype{0}, channels{0};
  std::vector<uint8_t> idat;
  uint8_t plte[256][4] = {};
  int plteN{0};
  bool hasKey{false};
  uint16_t key[3] = {};  // tRNS colour key for grey / RGB
};

bool ValidDepth(int ctype, int depth) {
  switch (ctype) {
    case 0: return depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16;
    case 3: return depth == 1 || depth == 2 || depth == 4 || depth == 8;
    case 2: case 4: case 6: return depth == 8 || depth == 16;
    default: return false;
  }
}

bool Parse(const uint8_t* d, size_t n, Png& png) {
  static const uint8_t kSig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
  if (n < 8 || std::memcmp(d, kSig, 8) != 0) return false;
  bool ihdr = false;
  for (size_t off = 8; off + 12 <= n;) {
    const uint32_t len = Be32(d + off);
    const uint8_t* type = d + off + 4;
    const uint8_t* body = d + off + 8;
    if (len > n - off - 12) return false;
    off += 12 + (size_t)len;
    if (std::memcmp(type, "IHDR", 4) == 0) {
      if (len != 13) return false;
      png.w = (int)Be32(body);
      png.h = (int)Be32(body + 4);
      png.depth = body[8];
      png.ctype = body[9];
      // compression and filter method 0 only; interlaced goes to stb_image
      if (body[10] != 0 || body[11] != 0 || body[12] != 0) return false;
      if (png.w <= 0 || png.h <= 0 || png.w > (1 << 24) || png.h > (1 << 24)) return false;
      if (!ValidDepth(png.ctype, png.depth)) return false;
      static const int kCh[7] = {1, 0, 3, 1, 2, 0, 4};
      png.channels = kCh[png.ctype];
      ihdr = true;
    } else if (!ihdr || std::memcmp(type, "CgBI", 4) == 0) {
      return false;
    } else if (std::memcmp(type, "PLTE", 4) == 0) {
      if (len % 3 != 0 || len > 768) return false;
      png.plteN = (int)len / 3;
      for (int i = 0; i < png.plteN; ++i) {
        png.plte[i][0] = body[i * 3];
        png.plte[i][1] = body[i * 3 + 1];
        png.plte[i][2] = body[i * 3 + 2];
        png.plte[i][3] = 255;
      }
    } else if (std::memcmp(type, "tRNS", 4) == 0) {
      if (png.ctype == 3) {
        for (uint32_t i = 0; i < len && i < 256; ++i) png.plte[i][3] = body[i];
      } else if (png.ctype == 0 && len >= 2) {
        png.hasKey = true;
        png.key[0] = (uint16_t)((body[0] << 8) | body[1]);
      } else if (png.ctype == 2 && len >= 6) {
        png.hasKey = true;
        for (int c = 0; c < 3; ++c) png.key[c] = (uint16_t)((body[c * 2] << 8) | body[c * 2 + 1]);
      }
    } else if (std::memcmp(type, "IDAT", 4) == 0) {
      png.idat.insert(png.idat.end(), body, body + len);
    } else if (std::memcmp(type, "IEND", 4) == 0) {
      break;
    }
  }
  return ihdr && !png.idat.empty() && (png.ctype != 3 || png.plteN > 0);
}

uint8_t Paeth(int a, int b, int c) {
  const int p = a + b - c;
  const int pa = p > a ? p - a : a - p, pb = p > b ? p - b : b - p, pc = p > c ? p - c : c - p;
  if (pa <= pb && pa <= pc) return (uint8_t)a;
  return (uint8_t)(pb <= pc ? b : c);
}

struct Rows {
  const Png& png;
  const RowSink& sink;
  size_t rowBytes, bpp;
  std::vector<uint8_t> prev, cur, rgba;
  size_t fill{0};
  int y{0};
  bool bad{false};

  Rows(const Png& p, const RowSink& s)
      : png(p), sink(s),
        rowBytes(((size_t)p.w * (size_t)p.channels * (size_t)p.depth + 7) / 8),
        bpp(p.channels * p.depth >= 8 ? (size_t)(p.channels * p.depth / 8) : 1),
        prev(rowBytes + 1, 0), cur(rowBytes + 1, 0), rgba((size_t)p.w * 4) {}

  bool Unfilter() {
    uint8_t* x = cur.data() + 1;
    const uint8_t* up = prev.data() + 1;
    switch (cur[0]) {
      case 0: break;
      case 1: for (size_t i = bpp; i < rowBytes; ++i) x[i] = (uint8_t)(x[i] + x[i - bpp]); break;
      case 2: for (size_t i = 0; i < rowBytes; ++i) x[i] = (uint8_t)(x[i] + up[i]); break;
      case 3:
        for (size_t i = 0; i < rowBytes; ++i)
          x[i] = (uint8_t)(x[i] + (((i >= bpp ? x[i - bpp] : 0) + up[i]) >> 1));
        break;
      case 4:
        for (size_t i = 0; i < rowBytes; ++i)
          x[i] = (uint8_t)(x[i] + Paeth(i >= bpp ? x[i - bpp] : 0, up[i], i >= bpp ? up[i - bpp] : 0));
        break;
      default: return false;
    }
    return true;
  }

  // Raw sample (unscaled) of channel c at pixel i.
  uint32_t Sample(const uint8_t* x, int i, int c) const {
    const size_t s = (size_t)i * png.channels + c;
    if (png.depth == 8) return x[s];
    if (png.depth == 16) return ((uint32_t)x[s * 2] << 8) | x[s * 2 + 1];
    const size_t bit = s * png.depth;
    return (x[bit >> 3] >> (8 - png.depth - (bit & 7))) & ((1u << png.depth) - 1);
  }
  uint8_t To8(uint32_t v) const {  // stb_image: 16-bit keeps the high byte, low depths scale up
    if (png.depth == 16) return (uint8_t)(v >> 8);
    if (png.depth == 8) return (uint8_t)v;
    return (uint8_t)(v * 255 / ((1u << png.depth) - 1));
  }

  void Convert() {
    const uint8_t* x = cur.data() + 1;
    for (int i = 0; i < png.w; ++i) {
      uint8_t* o = &rgba[(size_t)i * 4];
      uint32_t r, g, b, a = 255;
      switch (png.ctype) {
        case 0:
          r = Sample(x, i, 0);
          if (png.hasKey && r == png.key[0]) a = 0;
          o[0] = o[1] = o[2] = To8(r);
          break;
        case 2:
          r = Sample(x, i, 0); g = Sample(x, i, 1); b = Sample(x, i, 2);
          if (png.hasKey && r == png.key[0] && g == png.key[1] && b == png.key[2]) a = 0;
          o[0] = To8(r); o[1] = To8(g); o[2] = To8(b);
          break;
        case 3: {
          const uint32_t idx = Sample(x, i, 0);
          const uint8_t* p = png.plte[idx < (uint32_t)png.plteN ? idx : 0];
          o[0] = p[0]; o[1] = p[1]; o[2] = p[2];
          a = p[3];
          break;
        }
        case 4:
          o[0] = o[1] = o[2] = To8(Sample(x, i, 0));
          a = To8(Sample(x, i, 1));
          break;
        default:
          o[0] = To8(Sample(x, i, 0)); o[1] = To8(Sample(x, i, 1)); o[2] = To8(Sample(x, i, 2));
          a = To8(Sample(x, i, 3));
          break;
      }
      o[3] = (uint8_t)a;
      if (a != 255) {
        for (int c = 0; c < 3; ++c) o[c] = (uint8_t)((o[c] * a + 127) / 255);
      }
    }
  }

  static bool Feed(void* user, const uint8_t* d, size_t n) {
    Rows& r = *static_cast<Rows*>(user);
    const size_t stride = r.rowBytes + 1;
    while (n > 0) {
      const size_t take = std::min(n, stride - r.fill);
      std::memcpy(r.cur.data() + r.fill, d, take);
      r.fill += take;
      d += take;
      n -= take;
      if (r.fill < stride) continue;
      r.fill = 0;
      if (!r.Unfilter()) {
        r.bad = true;
        return false;
      }
      r.Convert();
      r.sink(r.rgba.data(), r.y);
      std::swap(r.prev, r.cur);
      if (++r.y == r.png.h) return false;  // every row delivered
    }
    return true;
  }
};

}  // namespace

bool PngDecodeRows(const uint8_t* data, size_t n, const RowSink& sink) {
  Png png;
  if (!Parse(data, n, png)) return false;
  Rows rows(png, sink);
  if (!InflateZlib(png.idat.data(), png.idat.size(), &Rows::Feed, &rows)) return false;
  return !rows.bad && rows.y == png.h;
}

}  // namespace rni::image
