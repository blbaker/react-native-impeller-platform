// A19 (SC-30): <Image> painting, see ImagePaint.h.
#include "base/Trace.h"
#include "scenegraph/ImagePaint.h"

#include <algorithm>

#include "fabric/ImageStore.h"

namespace rni {

namespace {

void ReleaseDecoded(void* userData) {
  delete static_cast<std::shared_ptr<const image::Decoded>*>(userData);
}

}  // namespace

ImageTextures::~ImageTextures() {
  for (auto& [uri, e] : entries_) {
    if (e.texture) ImpellerTextureRelease(e.texture);
  }
}

ImpellerTexture ImageTextures::Get(ImpellerContext context, RasterJobs* jobs,
                                   const std::string& uri, int* outW, int* outH) {
  auto it = entries_.find(uri);
  // FP-14: an upload whose frame was dropped never ran; upload again.
  if (it != entries_.end() && JobFailed(it->second.job)) {
    if (it->second.texture) ImpellerTextureRelease(it->second.texture);
    entries_.erase(it);
    it = entries_.end();
  }
  if (it == entries_.end()) {
    Entry e;
    auto d = image::Load(uri);
    if (d && context && jobs) {
      uint32_t name = 0;
      e.texture = jobs->WrapNewName(d->width, d->height, &name);
      if (e.texture == nullptr) return nullptr;  // pool empty: next frame
      e.job = jobs->AddUpload(e.texture, name, d->width, d->height, d->rgba.data(), d,
                              /*allocate=*/true, /*clampEdges=*/false, /*image=*/true);
      e.width = d->width;
      e.height = d->height;
    } else if (d && context) {
      ImpellerTextureDescriptor desc = {kImpellerPixelFormatRGBA8888, {d->width, d->height}, 1};
      // The mapping keeps the decoded pixels alive until Impeller has uploaded them.
      ImpellerMapping mapping = {d->rgba.data(), (uint64_t)d->rgba.size(), &ReleaseDecoded};
      TRACE_EVENT0("image", "ImageUpload");
      e.texture = ImpellerTextureCreateWithContentsNew(
          context, &desc, &mapping, new std::shared_ptr<const image::Decoded>(d));
      e.width = d->width;
      e.height = d->height;
    }
    // No context yet: do not cache the miss, a later paint may have one.
    if (!context) return nullptr;
    // SC-31: a remote source with no pixels yet is still loading (or will retry).
    if (!d && image::IsRemote(uri)) return nullptr;
    it = entries_.emplace(uri, e).first;
  }
  *outW = it->second.width;
  *outH = it->second.height;
  return it->second.texture;
}

void PaintImage(ImpellerDisplayListBuilder builder, ImpellerTexture texture, int texW, int texH,
                float scale, float x, float y, float w, float h, int resizeMode,
                const float* tint, float alpha) {
  if (texture == nullptr || texW <= 0 || texH <= 0 || w <= 0.0f || h <= 0.0f) return;
  if (scale <= 0.0f) scale = 1.0f;
  const float iw = (float)texW / scale;  // natural size in points
  const float ih = (float)texH / scale;

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
