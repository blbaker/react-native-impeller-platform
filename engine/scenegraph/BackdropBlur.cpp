#include "scenegraph/BackdropBlur.h"

#include <algorithm>

namespace rni {

namespace {

ImpellerColor Rgba(int r, int g, int b, float a) {
  return {r / 255.0f, g / 255.0f, b / 255.0f, std::clamp(a, 0.0f, 1.0f), kImpellerColorSpaceSRGB};
}

}  // namespace

ImpellerColor BlurTintColor(const std::string& tint, float intensity) {
  const float o = std::clamp(intensity, 0.0f, 100.0f) / 100.0f;
  if (tint == "dark" || tint == "systemMaterialDark") return Rgba(25, 25, 25, o * 0.78f);
  if (tint == "light" || tint == "extraLight" || tint == "systemMaterialLight" ||
      tint == "systemUltraThinMaterialLight" || tint == "systemThickMaterialLight")
    return Rgba(249, 249, 249, o * 0.78f);
  if (tint == "regular") return Rgba(179, 179, 179, o * 0.82f);
  if (tint == "systemThinMaterial") return Rgba(199, 199, 199, o * 0.97f);
  if (tint == "systemChromeMaterial") return Rgba(255, 255, 255, o * 0.75f);
  if (tint == "systemChromeMaterialLight") return Rgba(255, 255, 255, o * 0.97f);
  if (tint == "systemUltraThinMaterial" || tint == "systemThickMaterial")
    return Rgba(191, 191, 191, o * 0.44f);
  if (tint == "systemThickMaterialDark") return Rgba(37, 37, 37, o * 0.9f);
  if (tint == "systemThinMaterialDark") return Rgba(37, 37, 37, o * 0.7f);
  if (tint == "systemUltraThinMaterialDark") return Rgba(37, 37, 37, o * 0.55f);
  if (tint == "systemChromeMaterialDark") return Rgba(0, 0, 0, o * 0.75f);
  if (tint == "systemThinMaterialLight") return Rgba(199, 199, 199, o * 0.78f);
  // default, prominent, systemMaterial, and anything unknown.
  return Rgba(255, 255, 255, o * 0.3f);
}

float BlurSigmaForIntensity(float intensity) {
  const float r = std::clamp(intensity, 0.0f, 100.0f);
  return r > 0.0f ? r / 1.73205080757f + 0.5f : 0.0f;
}

void PaintBackdropBlur(ImpellerDisplayListBuilder builder, const ImpellerRect& box,
                       const std::string& tint, float intensity) {
  const float sigma = BlurSigmaForIntensity(intensity);
  if (sigma <= 0.0f || box.width <= 0.0f || box.height <= 0.0f) return;
  // Clamp, not decal: pixels past the window edge repeat the edge instead of
  // fading the blur to transparent (Flutter's ImageFilter.blur default).
  ImpellerImageFilter backdrop = ImpellerImageFilterCreateBlurNew(sigma, sigma, kImpellerTileModeClamp);
  ImpellerDisplayListBuilderSaveLayer(builder, &box, nullptr, backdrop);
  ImpellerImageFilterRelease(backdrop);
  ImpellerPaint p = ImpellerPaintNew();
  const ImpellerColor c = BlurTintColor(tint, intensity);
  ImpellerPaintSetColor(p, &c);
  ImpellerDisplayListBuilderDrawRect(builder, &box, p);
  ImpellerPaintRelease(p);
  ImpellerDisplayListBuilderRestore(builder);
}

}  // namespace rni
