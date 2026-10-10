#include "scenegraph/BlendGroup.h"

namespace rni {

ImpellerBlendMode ToImpellerBlend(facebook::react::BlendMode mode) {
  using facebook::react::BlendMode;
  switch (mode) {
    case BlendMode::Multiply: return kImpellerBlendModeMultiply;
    case BlendMode::Screen: return kImpellerBlendModeScreen;
    case BlendMode::Overlay: return kImpellerBlendModeOverlay;
    case BlendMode::Darken: return kImpellerBlendModeDarken;
    case BlendMode::Lighten: return kImpellerBlendModeLighten;
    case BlendMode::ColorDodge: return kImpellerBlendModeColorDodge;
    case BlendMode::ColorBurn: return kImpellerBlendModeColorBurn;
    case BlendMode::HardLight: return kImpellerBlendModeHardLight;
    case BlendMode::SoftLight: return kImpellerBlendModeSoftLight;
    case BlendMode::Difference: return kImpellerBlendModeDifference;
    case BlendMode::Exclusion: return kImpellerBlendModeExclusion;
    case BlendMode::Hue: return kImpellerBlendModeHue;
    case BlendMode::Saturation: return kImpellerBlendModeSaturation;
    case BlendMode::Color: return kImpellerBlendModeColor;
    case BlendMode::Luminosity: return kImpellerBlendModeLuminosity;
    case BlendMode::PlusLighter: return kImpellerBlendModePlus;
    default: return kImpellerBlendModeSourceOver;
  }
}

void BeginBlendGroup(ImpellerDisplayListBuilder builder, ImpellerBlendMode mode) {
  ImpellerPaint p = ImpellerPaintNew();
  ImpellerPaintSetBlendMode(p, mode);
  const ImpellerRect bounds = {-100000.0f, -100000.0f, 200000.0f, 200000.0f};
  ImpellerDisplayListBuilderSaveLayer(builder, &bounds, p, nullptr);
  ImpellerPaintRelease(p);
}

}  // namespace rni
