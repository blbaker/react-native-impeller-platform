// FP-16: one encoded image -> premultiplied RGBA8 at the decode size for a box
// (model: ImageDecoderImpeller::DecompressTexture,
// engine/src/flutter/lib/ui/painting/image_decoder_impeller.cc L333-L424).
#include "ImageDecode.h"

#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

#include "ImageInternal.h"
#include "ImageResize.h"
#include "PngStream.h"
#include "base/Trace.h"

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_GIF
#define STBI_ONLY_BMP
#define STBI_NO_STDIO
#include "stb_image.h"

namespace rni::image {
namespace {

void Premultiply(uint8_t* px, size_t n) {
  for (size_t i = 0; i < n; i += 4) {
    const unsigned a = px[i + 3];
    if (a == 255) continue;
    for (int c = 0; c < 3; ++c) px[i + c] = (uint8_t)((px[i + c] * a + 127) / 255);
  }
}

std::atomic<int> gLive{0}, gPeak{0}, gDecodes{0}, gMaxTexture{8192};

std::string SizeKey(int w, int h) { return std::to_string(w) + "x" + std::to_string(h); }

void Report(const std::shared_ptr<const Decoded>& d, int bw, int bh, const std::string& uri) {
  static const bool log = EnvInt("RNI_IMAGE_LOG") > 0;
  static const char* dump = std::getenv("RNI_TEST_IMAGE_DUMP");
  static std::atomic<int> seq{0};
  if (!d) return;
  if (log) {
    std::printf("rn-impeller: image_decode src=%dx%d box=%dx%d out=%dx%d\n", d->srcWidth,
                d->srcHeight, bw, bh, d->width, d->height);
  }
  if (dump == nullptr || *dump == '\0') return;
  std::string base = uri.substr(uri.find_last_of('/') + 1);
  for (char& c : base) if (!std::isalnum((unsigned char)c) && c != '.' && c != '-') c = '_';
  const std::string path = std::string(dump) + "/decode-" + std::to_string(seq.fetch_add(1)) + "-" +
                           base + "-" + SizeKey(d->width, d->height) + ".pam";
  if (FILE* f = std::fopen(path.c_str(), "wb")) {
    std::fprintf(f, "P7\nWIDTH %d\nHEIGHT %d\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n",
                 d->width, d->height);
    std::fwrite(d->rgba.data(), 1, d->rgba.size(), f);
    std::fclose(f);
  }
}

bool IsPng(const uint8_t* d, size_t n) { return n >= 8 && d[0] == 137 && d[1] == 'P' && d[2] == 'N'; }

}  // namespace

std::shared_ptr<const Decoded> DecodeBytes(const uint8_t* data, size_t n, int boxW, int boxH,
                                           int maxTexture) {
  TRACE_EVENT1("image", "ImageDecode", "bytes", n);
  if (data == nullptr || n == 0 || n > (size_t)INT32_MAX) return nullptr;
  int sw = 0, sh = 0, comp = 0;
  if (!stbi_info_from_memory(data, (int)n, &sw, &sh, &comp) || sw <= 0 || sh <= 0) return nullptr;
  const PixelSize out = DecodeSize(sw, sh, boxW, boxH, maxTexture);
  auto d = std::make_shared<Decoded>();
  d->srcWidth = sw;
  d->srcHeight = sh;
  d->width = out.width;
  d->height = out.height;
  d->rgba.assign((size_t)out.width * (size_t)out.height * 4, 0);

  const bool resize = out.width != sw || out.height != sh;
  if (resize && IsPng(data, n)) {
    // Rows stream through the area filter: the full-size bitmap never exists.
    AreaDownscaler ds(sw, sh, out.width, out.height, d->rgba.data());
    if (PngDecodeRows(data, n, [&ds](const uint8_t* row, int) { ds.Push(row); }) && ds.Done()) {
      return d;
    }
  }
  int w = 0, h = 0;
  stbi_uc* px = stbi_load_from_memory(data, (int)n, &w, &h, &comp, 4);
  if (px == nullptr || w != sw || h != sh) {
    if (px) stbi_image_free(px);
    return nullptr;
  }
  if (!resize) {
    std::memcpy(d->rgba.data(), px, d->rgba.size());
    Premultiply(d->rgba.data(), d->rgba.size());
  } else {
    TRACE_EVENT0("image", "ImageResizeOnCpu");
    AreaDownscaler ds(sw, sh, out.width, out.height, d->rgba.data());
    std::vector<uint8_t> row((size_t)sw * 4);
    for (int y = 0; y < sh; ++y) {
      std::memcpy(row.data(), px + (size_t)y * sw * 4, row.size());
      Premultiply(row.data(), row.size());
      ds.Push(row.data());
    }
  }
  stbi_image_free(px);
  return d;
}

// Every decode, pool or not, goes through here: gPeak is the most decodes ever running at once.
std::shared_ptr<const Decoded> RunDecode(const uint8_t* data, size_t n, int bw, int bh,
                                         const std::string& uri) {
  static const int delayMs = EnvInt("RNI_TEST_IMAGE_DECODE_DELAY_MS");
  const int live = gLive.fetch_add(1) + 1;
  for (int peak = gPeak.load(); live > peak && !gPeak.compare_exchange_weak(peak, live);) {}
  if (delayMs > 0) std::this_thread::sleep_for(std::chrono::milliseconds(delayMs));
  auto d = DecodeBytes(data, n, bw, bh, MaxTextureSize());
  gLive.fetch_sub(1);
  gDecodes.fetch_add(1);
  Report(d, bw, bh, uri);
  return d;
}

int DecodeCount() { return gDecodes.load(); }
int PeakLiveDecodes() { return gPeak.load(); }

int EnvInt(const char* name) {
  const char* v = std::getenv(name);
  return v ? std::atoi(v) : 0;
}

void SetMaxTextureSize(int px) {
  if (px > 0) gMaxTexture.store(px);
}

int MaxTextureSize() {
  static const int forced = EnvInt("RNI_TEST_MAX_TEXTURE_SIZE");
  return forced > 0 ? forced : gMaxTexture.load();
}

}  // namespace rni::image
