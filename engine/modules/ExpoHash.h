// ExpoHash — MD5 and SHA-1, header-only, no dependencies.
//
// WHY THE ENGINE CARRIES ITS OWN. The Expo host needs exactly two digests:
//   - MD5:   expo-asset's cache file name is `ExponentAsset-<md5>.<type>`, and
//            a cached file is reused only when its content MD5 matches the
//            hash the bundler recorded (AssetModule.swift, same rule).
//   - SHA-1: `expo.uuidv5` is RFC 4122 name-based UUID version 5.
// OpenSSL is linked on linux/darwin only (win32 has no TLS stack at all), so a
// libcrypto call would compile on two of three hosts. These are ~100 lines
// and are checked against Python's hashlib/uuid in tools/ci-expo-host.sh.
//
// NOT FOR SECURITY. MD5 here is a content fingerprint, exactly as Expo uses it.
#pragma once

#include <array>
#include <cmath>
#include <cstdint>
#include <string>

namespace rni::expohash {

inline uint32_t rotl32(uint32_t x, int n) {
  return (x << n) | (x >> (32 - n));
}

inline std::string toHex(const uint8_t* bytes, size_t n) {
  static const char* kHex = "0123456789abcdef";
  std::string out;
  out.reserve(n * 2);
  for (size_t i = 0; i < n; ++i) {
    out.push_back(kHex[bytes[i] >> 4]);
    out.push_back(kHex[bytes[i] & 0x0f]);
  }
  return out;
}

// RFC 1321.
inline std::array<uint8_t, 16> md5(const std::string& data) {
  // K[i] = floor(2^32 * |sin(i + 1)|). Computed rather than transcribed: a
  // mistyped constant is a silent wrong digest, a computed one is not (the
  // doubles involved have ~20 bits of headroom over the 32 needed).
  static const std::array<uint32_t, 64> K = [] {
    std::array<uint32_t, 64> k{};
    for (int i = 0; i < 64; ++i) {
      k[i] = static_cast<uint32_t>(
          std::floor(std::fabs(std::sin(static_cast<double>(i + 1))) * 4294967296.0));
    }
    return k;
  }();
  static const int S[64] = {7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                            5, 9,  14, 20, 5, 9,  14, 20, 5, 9,  14, 20, 5, 9,  14, 20,
                            4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                            6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21};
  uint32_t a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;

  std::string msg = data;
  const uint64_t bitLen = static_cast<uint64_t>(data.size()) * 8;
  msg.push_back(static_cast<char>(0x80));
  while (msg.size() % 64 != 56) msg.push_back('\0');
  for (int i = 0; i < 8; ++i) {
    msg.push_back(static_cast<char>((bitLen >> (8 * i)) & 0xff));  // little-endian
  }

  for (size_t off = 0; off < msg.size(); off += 64) {
    uint32_t M[16];
    for (int i = 0; i < 16; ++i) {
      const auto* p = reinterpret_cast<const uint8_t*>(msg.data() + off + i * 4);
      M[i] = uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) |
             (uint32_t(p[3]) << 24);
    }
    uint32_t A = a0, B = b0, C = c0, D = d0;
    for (int i = 0; i < 64; ++i) {
      uint32_t F;
      int g;
      if (i < 16) {
        F = (B & C) | (~B & D);
        g = i;
      } else if (i < 32) {
        F = (D & B) | (~D & C);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        F = B ^ C ^ D;
        g = (3 * i + 5) % 16;
      } else {
        F = C ^ (B | ~D);
        g = (7 * i) % 16;
      }
      F = F + A + K[i] + M[g];
      A = D;
      D = C;
      C = B;
      B = B + rotl32(F, S[i]);
    }
    a0 += A;
    b0 += B;
    c0 += C;
    d0 += D;
  }

  std::array<uint8_t, 16> out{};
  const uint32_t words[4] = {a0, b0, c0, d0};
  for (int w = 0; w < 4; ++w) {
    for (int i = 0; i < 4; ++i) out[w * 4 + i] = (words[w] >> (8 * i)) & 0xff;
  }
  return out;
}

inline std::string md5Hex(const std::string& data) {
  auto d = md5(data);
  return toHex(d.data(), d.size());
}

// FIPS 180-1.
inline std::array<uint8_t, 20> sha1(const std::string& data) {
  uint32_t h[5] = {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0};
  std::string msg = data;
  const uint64_t bitLen = static_cast<uint64_t>(data.size()) * 8;
  msg.push_back(static_cast<char>(0x80));
  while (msg.size() % 64 != 56) msg.push_back('\0');
  for (int i = 7; i >= 0; --i) {
    msg.push_back(static_cast<char>((bitLen >> (8 * i)) & 0xff));  // big-endian
  }

  for (size_t off = 0; off < msg.size(); off += 64) {
    uint32_t w[80];
    for (int i = 0; i < 16; ++i) {
      const auto* p = reinterpret_cast<const uint8_t*>(msg.data() + off + i * 4);
      w[i] = (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) |
             uint32_t(p[3]);
    }
    for (int i = 16; i < 80; ++i) {
      w[i] = rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
    for (int i = 0; i < 80; ++i) {
      uint32_t f, k;
      if (i < 20) {
        f = (b & c) | (~b & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      const uint32_t temp = rotl32(a, 5) + f + e + k + w[i];
      e = d;
      d = c;
      c = rotl32(b, 30);
      b = a;
      a = temp;
    }
    h[0] += a;
    h[1] += b;
    h[2] += c;
    h[3] += d;
    h[4] += e;
  }

  std::array<uint8_t, 20> out{};
  for (int w = 0; w < 5; ++w) {
    for (int i = 0; i < 4; ++i) out[w * 4 + i] = (h[w] >> (24 - 8 * i)) & 0xff;
  }
  return out;
}

}  // namespace rni::expohash
