// A19 (SC-30): <Image> painting, see ImagePaint.h.
#include "base/Trace.h"
#include "scenegraph/ImagePaint.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>

#include "fabric/ImageStore.h"

namespace rni {

namespace {

void ReleaseDecoded(void* userData) {
  delete static_cast<std::shared_ptr<const image::Decoded>*>(userData);
}

}  // namespace

ImageTextures::~ImageTextures() {
  for (auto& [d, e] : entries_) {
    if (e.texture) ImpellerTextureRelease(e.texture);
  }
}

ImpellerTexture ImageTextures::Get(ImpellerContext context, const std::string& uri, float boxW,
                                   float boxH, ImageTextureInfo* info) {
  if (!context) return nullptr;
  // FP-16: the cached decode for this box's size bucket (or the best other
  // size of the URI). A load in flight paints nothing yet; its completion
  // wakes the frame loop. Only a local source nobody requested (defaultSource)
  // is decoded here, synchronously, like RN iOS loads its default image.
  image::Lookup f = image::Find(uri, boxW, boxH);
  if (!f.image && !f.failed && !f.pending) f.image = image::DecodeNow(uri, boxW, boxH);
  if (!f.image) return nullptr;
  auto it = entries_.find(f.image.get());
  if (it == entries_.end()) {
    const auto& d = f.image;
    Entry e;
    e.decoded = d;
    ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888, {d->width, d->height}, 1};
    // The mapping keeps the decoded pixels alive until Impeller has uploaded them.
    ImpellerMapping mapping = {d->rgba.data(), (uint64_t)d->rgba.size(), &ReleaseDecoded};
    {
      TRACE_EVENT0("image", "ImageUpload");
      e.texture = ImpellerTextureCreateWithContentsNew(
          context, &desc, &mapping, new std::shared_ptr<const image::Decoded>(d));
    }
    static const bool log = std::getenv("RNI_IMAGE_LOG") != nullptr;
    if (log) std::printf("rn-impeller: image_upload w=%d h=%d src=%dx%d box=%.0fx%.0f\n", d->width,
                         d->height, d->srcWidth, d->srcHeight, boxW, boxH);
    it = entries_.emplace(d.get(), std::move(e)).first;
  }
  const image::Decoded& d = *it->second.decoded;
  info->texWidth = d.width;
  info->texHeight = d.height;
  info->srcWidth = d.srcWidth;
  info->srcHeight = d.srcHeight;
  return it->second.texture;
}

void PaintImage(ImpellerDisplayListBuilder builder, ImpellerTexture texture,
                const ImageTextureInfo& info, float scale, float x, float y, float w, float h,
                int resizeMode, const float* tint, float alpha) {
  const int texW = info.texWidth, texH = info.texHeight;
  if (texture == nullptr || texW <= 0 || texH <= 0 || w <= 0.0f || h <= 0.0f) return;
  if (scale <= 0.0f) scale = 1.0f;
  const float iw = (float)info.srcWidth / scale;  // natural size in points (source pixels)
  const float ih = (float)info.srcHeight / scale;

  ImpellerPaint paint = ImpellerPaintNew();
  const ImpellerColor base = {1.0f, 1.0f, 1.0f, alpha, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &base);
  if (tint != nullptr) {
    const ImpellerColor tc = {tint[0], tint[1], tint[2], tint[3], kImpellerColorSpaceSRGB};
    ImpellerColorFilter cf = ImpellerColorFilterCreateBlendNew(&tc, kImpellerBlendModeSourceIn);
    if (cf) {
      ImpellerPaintSetColorFilter(paint, cf);
      ImpellerColorFilterRelease(cf);
    }
  }

  const ImpellerRect src = {0.0f, 0.0f, (float)texW, (float)texH};
  if (resizeMode == 4) {  // repeat: natural-size tiles from the top-left corner
    const ImpellerMatrix m = {{iw / (float)texW, 0, 0, 0, 0, ih / (float)texH, 0, 0, 0, 0, 1, 0,
                               x, y, 0, 1}};
    ImpellerColorSource cs = ImpellerColorSourceCreateImageNew(
        texture, kImpellerTileModeRepeat, kImpellerTileModeRepeat,
        kImpellerTextureSamplingLinear, &m);
    if (cs) {
      ImpellerPaintSetColorSource(paint, cs);
      ImpellerColorSourceRelease(cs);
      const ImpellerRect r = {x, y, w, h};
      ImpellerDisplayListBuilderDrawRect(builder, &r, paint);
    }
    ImpellerPaintRelease(paint);
    return;
  }

  ImpellerRect dst = {x, y, w, h};
  float s = 1.0f;
  switch (resizeMode) {
    case 0: s = std::max(w / iw, h / ih); break;          // cover
    case 1: s = std::min(w / iw, h / ih); break;          // contain
    case 3: s = std::min(1.0f, std::min(w / iw, h / ih)); break;  // center: shrink only
    case 5: s = 1.0f; break;                              // none: natural size, top-left
    default: break;                                       // stretch
  }
  if (resizeMode == 0 || resizeMode == 1 || resizeMode == 3) {
    const float dw = iw * s, dh = ih * s;
    dst = {x + (w - dw) * 0.5f, y + (h - dh) * 0.5f, dw, dh};
  } else if (resizeMode == 5) {
    dst = {x, y, iw, ih};
  }
  ImpellerDisplayListBuilderDrawTextureRect(builder, texture, &src, &dst,
                                            kImpellerTextureSamplingLinear, paint);
  ImpellerPaintRelease(paint);
}

}  // namespace rni
