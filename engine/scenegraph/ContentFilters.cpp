#include "scenegraph/ContentFilters.h"

#include <algorithm>
#include <variant>

#include "scenegraph/ColorMatrixFilter.h"

namespace rni {

using facebook::react::DropShadowParams;
using facebook::react::FilterType;

void ParseContentFilters(const std::vector<facebook::react::FilterFunction>& filters,
                         float& blurSigma, std::vector<ShadowSpec>& dropShadows) {
  blurSigma = 0.0f;
  dropShadows.clear();
  for (const auto& f : filters) {
    if (f.type == FilterType::Blur && std::holds_alternative<facebook::react::Float>(f.parameters)) {
      blurSigma += std::max(0.0f, static_cast<float>(std::get<facebook::react::Float>(f.parameters)));
    } else if (f.type == FilterType::DropShadow &&
               std::holds_alternative<DropShadowParams>(f.parameters)) {
      const auto& p = std::get<DropShadowParams>(f.parameters);
      ShadowSpec s;
      s.offsetX = static_cast<float>(p.offsetX);
      s.offsetY = static_cast<float>(p.offsetY);
      s.sigma = std::max(0.0f, static_cast<float>(p.standardDeviation)) * 0.5f;
      if (p.color) {
        const auto c = facebook::react::colorComponentsFromColor(p.color);
        s.color[0] = c.red;
        s.color[1] = c.green;
        s.color[2] = c.blue;
        s.color[3] = c.alpha;
      }
      dropShadows.push_back(s);
    }
  }
}

ImpellerImageFilter MakeBlurImageFilter(float sigma) {
  if (sigma <= 0.0f) return nullptr;
  return ImpellerImageFilterCreateBlurNew(sigma, sigma, kImpellerTileModeDecal);
}

void BeginContentShadow(ImpellerDisplayListBuilder builder, const ShadowSpec& s) {
  ImpellerDisplayListBuilderSave(builder);
  ImpellerDisplayListBuilderTranslate(builder, s.offsetX, s.offsetY);
  ImpellerPaint p = ImpellerPaintNew();
  const ImpellerColor tint = {s.color[0], s.color[1], s.color[2], s.color[3],
                              kImpellerColorSpaceSRGB};
  // SourceIn keeps the content's alpha and takes the shadow colour's rgb and alpha.
  ImpellerColorFilter cf = ImpellerColorFilterCreateBlendNew(&tint, kImpellerBlendModeSourceIn);
  if (cf != nullptr) {
    ImpellerPaintSetColorFilter(p, cf);
    ImpellerColorFilterRelease(cf);
  }
  ImpellerImageFilter blur = MakeBlurImageFilter(s.sigma);
  if (blur != nullptr) {
    ImpellerPaintSetImageFilter(p, blur);
    ImpellerImageFilterRelease(blur);
  }
  const ImpellerRect bounds = {-100000.0f, -100000.0f, 200000.0f, 200000.0f};
  ImpellerDisplayListBuilderSaveLayer(builder, &bounds, p, nullptr);
  ImpellerPaintRelease(p);
}

void EndContentShadow(ImpellerDisplayListBuilder builder) {
  ImpellerDisplayListBuilderRestore(builder);  // the shadow layer
  ImpellerDisplayListBuilderRestore(builder);  // the offset
}

}  // namespace rni
