// A19 (SC-30): local <Image> source bytes: data: URIs, file:// URLs and paths.
// Split out of ImageStore.cpp by FP-16.
#include <cstdio>
#include <string>
#include <vector>

#include "ImageStore.h"

namespace rni::image {
namespace {

int HexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

std::string PercentDecode(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '%' && i + 2 < s.size() && HexVal(s[i + 1]) >= 0 && HexVal(s[i + 2]) >= 0) {
      out.push_back((char)(HexVal(s[i + 1]) * 16 + HexVal(s[i + 2])));
      i += 2;
    } else {
      out.push_back(s[i]);
    }
  }
  return out;
}

int B64Val(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+' || c == '-') return 62;
  if (c == '/' || c == '_') return 63;
  return -1;
}

void Base64Decode(const std::string& s, std::vector<uint8_t>& out) {
  uint32_t acc = 0;
  int bits = 0;
  for (char c : s) {
    const int v = B64Val(c);
    if (v < 0) continue;  // '=', whitespace, line breaks
    acc = (acc << 6) | (uint32_t)v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back((uint8_t)((acc >> bits) & 0xFF));
    }
  }
}

bool ReadFile(const std::string& path, std::vector<uint8_t>& out) {
  FILE* f = std::fopen(path.c_str(), "rb");
  if (f == nullptr) return false;
  uint8_t buf[65536];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) out.insert(out.end(), buf, buf + n);
  std::fclose(f);
  return !out.empty();
}

}  // namespace

bool ReadSourceBytes(const std::string& uri, std::vector<uint8_t>& out) {
  if (uri.rfind("data:", 0) == 0) {
    const size_t comma = uri.find(',');
    if (comma == std::string::npos) return false;
    const std::string meta = uri.substr(5, comma - 5);
    const std::string payload = uri.substr(comma + 1);
    if (meta.size() >= 7 && meta.compare(meta.size() - 7, 7, ";base64") == 0) {
      Base64Decode(payload, out);
    } else {
      const std::string raw = PercentDecode(payload);
      out.assign(raw.begin(), raw.end());
    }
    return !out.empty();
  }
  if (uri.rfind("file://", 0) == 0) {
    // file:///abs/path or file://localhost/abs/path
    std::string rest = uri.substr(7);
    if (rest.rfind("localhost/", 0) == 0) rest = rest.substr(9);
    const size_t q = rest.find_first_of("?#");
    if (q != std::string::npos) rest.resize(q);
    return ReadFile(PercentDecode(rest), out);
  }
  if (!uri.empty() && uri[0] == '/') return ReadFile(uri, out);
#ifdef _WIN32
  if (uri.size() > 2 && uri[1] == ':') return ReadFile(uri, out);
#endif
  return false;
}

bool IsRemote(const std::string& uri) {
  return uri.rfind("http://", 0) == 0 || uri.rfind("https://", 0) == 0;
}

}  // namespace rni::image
