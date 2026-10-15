// FP-16: streaming inflate, see Inflate.h. Canonical Huffman decoding as in
// zlib's contrib/puff, with a 10-bit lookup table in front of it.
#include "Inflate.h"

#include <algorithm>
#include <cstring>
#include <memory>

namespace rni::image {
namespace {

constexpr int kMaxBits = 15;
constexpr int kFastBits = 10;

const uint16_t kLenBase[29] = {3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23, 27,
                               31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
const uint8_t kLenExtra[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
                               2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
const uint16_t kDistBase[30] = {1,    2,    3,    4,    5,    7,     9,     13,    17,  25,
                                33,   49,   65,   97,   129,  193,   257,   385,   513, 769,
                                1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
const uint8_t kDistExtra[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6,
                                6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};
const uint8_t kClenOrder[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};

struct Huffman {
  uint16_t fast[1 << kFastBits];  // (len << 9) | symbol; 0 = take the slow path
  uint16_t count[kMaxBits + 1];
  uint16_t symbol[320];

  // Incomplete codes are allowed (a lone distance code); over-subscribed ones are not.
  bool Build(const uint8_t* lens, int n) {
    std::memset(count, 0, sizeof count);
    std::memset(fast, 0, sizeof fast);
    for (int i = 0; i < n; ++i) count[lens[i]]++;
    count[0] = 0;
    int left = 1;
    for (int len = 1; len <= kMaxBits; ++len) {
      left = (left << 1) - count[len];
      if (left < 0) return false;
    }
    uint16_t offs[kMaxBits + 2] = {};
    int next[kMaxBits + 1] = {};
    for (int len = 1, code = 0; len <= kMaxBits; ++len) {
      offs[len + 1] = (uint16_t)(offs[len] + count[len]);
      code = (code + count[len - 1]) << 1;
      next[len] = code;
    }
    for (int s = 0; s < n; ++s) {
      const int len = lens[s];
      if (len == 0) continue;
      symbol[offs[len]++] = (uint16_t)s;
      const int c = next[len]++;
      if (len > kFastBits) continue;
      int rev = 0;
      for (int b = 0; b < len; ++b) rev |= ((c >> b) & 1) << (len - 1 - b);
      for (int k = rev; k < (1 << kFastBits); k += 1 << len) fast[k] = (uint16_t)((len << 9) | s);
    }
    return true;
  }
};

struct Bits {
  const uint8_t* p;
  const uint8_t* end;
  uint64_t buf{0};
  int cnt{0};
  size_t pad{0};  // zero bytes appended past the end; consuming one is an error

  void Refill() {
    while (cnt <= 56) {
      uint64_t b = 0;
      if (p < end) b = *p++; else ++pad;
      buf |= b << cnt;
      cnt += 8;
    }
  }
  uint32_t Peek(int n) {
    if (cnt < n) Refill();
    return (uint32_t)(buf & ((1ull << n) - 1));
  }
  void Drop(int n) { buf >>= n; cnt -= n; }
  uint32_t Get(int n) { const uint32_t v = Peek(n); Drop(n); return v; }
  bool Bad() const { return (size_t)cnt < pad * 8; }
};

int Decode(Bits& br, const Huffman& h) {
  const uint32_t peek = br.Peek(kMaxBits);
  const uint16_t e = h.fast[peek & ((1u << kFastBits) - 1)];
  if (e != 0) {
    br.Drop(e >> 9);
    return e & 511;
  }
  int code = 0, first = 0, index = 0;
  for (int len = 1; len <= kMaxBits; ++len) {
    code |= (int)((peek >> (len - 1)) & 1);
    const int count = h.count[len];
    if (code - count < first) {
      br.Drop(len);
      return h.symbol[index + (code - first)];
    }
    index += count;
    first = (first + count) << 1;
    code <<= 1;
  }
  return -1;
}

struct Out {
  uint8_t win[1 << 16];
  uint64_t pos{0}, flushed{0};
  InflateSink sink{nullptr};
  void* user{nullptr};
  bool stopped{false};

  void Put(uint8_t b) { win[pos++ & 0xFFFF] = b; }
  bool Flush() {
    while (flushed < pos && !stopped) {
      const size_t start = (size_t)(flushed & 0xFFFF);
      const size_t n = (size_t)std::min<uint64_t>(pos - flushed, 65536 - start);
      if (!sink(user, win + start, n)) stopped = true;
      flushed += n;
    }
    return !stopped;
  }
  // Unflushed bytes stay below 32 KB + one match, so the ring never overwrites them.
  bool MaybeFlush() { return pos - flushed < 32768 || Flush(); }
};

bool Codes(Bits& br, Out& out, const Huffman& lit, const Huffman& dist) {
  for (;;) {
    int sym = Decode(br, lit);
    if (sym < 0) return false;
    if (sym < 256) {
      out.Put((uint8_t)sym);
    } else if (sym == 256) {
      return !br.Bad();
    } else {
      sym -= 257;
      if (sym >= 29) return false;
      const int len = kLenBase[sym] + (int)br.Get(kLenExtra[sym]);
      const int ds = Decode(br, dist);
      if (ds < 0 || ds >= 30) return false;
      const uint32_t d = kDistBase[ds] + br.Get(kDistExtra[ds]);
      if (d > out.pos) return false;
      for (int i = 0; i < len; ++i) out.Put(out.win[(out.pos - d) & 0xFFFF]);
    }
    if (br.Bad()) return false;
    if (!out.MaybeFlush()) return true;
  }
}

bool Dynamic(Bits& br, Huffman& lit, Huffman& dist) {
  const int hlit = (int)br.Get(5) + 257, hdist = (int)br.Get(5) + 1, hclen = (int)br.Get(4) + 4;
  if (hlit > 286 || hdist > 30) return false;
  uint8_t lens[320] = {};
  for (int i = 0; i < hclen; ++i) lens[kClenOrder[i]] = (uint8_t)br.Get(3);
  Huffman clen;
  if (!clen.Build(lens, 19)) return false;
  std::memset(lens, 0, sizeof lens);
  for (int i = 0; i < hlit + hdist;) {
    const int sym = Decode(br, clen);
    if (sym < 0 || br.Bad()) return false;
    if (sym < 16) {
      lens[i++] = (uint8_t)sym;
      continue;
    }
    uint8_t v = 0;
    int rep;
    if (sym == 16) {
      if (i == 0) return false;
      v = lens[i - 1];
      rep = 3 + (int)br.Get(2);
    } else if (sym == 17) {
      rep = 3 + (int)br.Get(3);
    } else {
      rep = 11 + (int)br.Get(7);
    }
    if (i + rep > hlit + hdist) return false;
    while (rep-- > 0) lens[i++] = v;
  }
  if (lens[256] == 0) return false;
  return lit.Build(lens, hlit) && dist.Build(lens + hlit, hdist);
}

}  // namespace

bool InflateZlib(const uint8_t* src, size_t n, InflateSink sink, void* user) {
  if (n < 2) return false;
  const int cmf = src[0], flg = src[1];
  if ((cmf & 15) != 8 || (cmf >> 4) > 7 || ((cmf << 8) | flg) % 31 != 0 || (flg & 32)) return false;
  Bits br{src + 2, src + n};
  auto out = std::make_unique<Out>();
  out->sink = sink;
  out->user = user;
  auto lit = std::make_unique<Huffman>();
  auto dist = std::make_unique<Huffman>();
  for (bool last = false; !last;) {
    last = br.Get(1) != 0;
    const uint32_t type = br.Get(2);
    if (type == 0) {
      br.Drop(br.cnt % 8);
      const uint32_t len = br.Get(16), nlen = br.Get(16);
      if (len != (~nlen & 0xFFFF)) return false;
      for (uint32_t i = 0; i < len; ++i) {
        out->Put((uint8_t)br.Get(8));
        if (!out->MaybeFlush()) return true;
      }
      if (br.Bad()) return false;
    } else if (type == 1 || type == 2) {
      if (type == 1) {
        uint8_t lens[320];
        std::memset(lens, 8, 144);
        std::memset(lens + 144, 9, 112);
        std::memset(lens + 256, 7, 24);
        std::memset(lens + 280, 8, 8);
        std::memset(lens + 288, 5, 30);
        lit->Build(lens, 288);
        dist->Build(lens + 288, 30);
      } else if (!Dynamic(br, *lit, *dist)) {
        return false;
      }
      if (!Codes(br, *out, *lit, *dist)) return false;
      if (out->stopped) return true;
    } else {
      return false;
    }
  }
  out->Flush();
  return true;
}

}  // namespace rni::image
