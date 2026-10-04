#pragma once
// Style audit items 1-3 (2026-10-04): View shadows.
//
// One painter for every RN shadow source, so the iOS shadow* props and the
// CSS boxShadow list cannot drift apart:
//   - shadowColor/shadowOffset/shadowOpacity/shadowRadius (iOS CALayer model)
//   - boxShadow, outer and inset (CSS model, RN 0.76+)
// elevation (Android) is separate: it is a material shadow drawn with
// ImpellerDisplayListBuilderDrawShadow, see PaintElevationShadow.

#include <vector>

#include "impeller.h"

namespace rni {

struct ShadowSpec {
  float offsetX{0};
  float offsetY{0};
  // Gaussian sigma in points. CSS blur radius B maps to sigma B/2; the iOS
  // shadowRadius r is already a sigma-sized value (CALayer r ~ CSS blur 2r).
  float sigma{0};
  float spread{0};
  float color[4]{0, 0, 0, 1};  // straight alpha, opacity already folded in
  bool inset{false};
  // CSS outer box-shadow is clipped OUT of the border box (a translucent
  // background never shows its own shadow through it). The iOS CALayer
  // shadow is not, so a half-transparent iOS card shows the shadow under it.
  bool clipOutsideBox{true};
};

struct ShadowBox {
  float x, y, w, h;               // border box, painted coordinates
  ImpellerRoundingRadii radii{};  // Impeller field order
  bool rounded{false};
};

// Outer shadows, painted BEFORE the background (behind the box).
void PaintOuterShadows(ImpellerDisplayListBuilder builder, const ShadowBox& box,
                       const std::vector<ShadowSpec>& shadows, float alpha);

// Inset shadows, painted AFTER the background and BEFORE the border, clipped
// to the padding box (border box minus border widths, top/right/bottom/left).
void PaintInsetShadows(ImpellerDisplayListBuilder builder, const ShadowBox& box,
                       const float borderWidths[4],
                       const std::vector<ShadowSpec>& shadows, float alpha);

// Android elevation: a material shadow under the box outline.
void PaintElevationShadow(ImpellerDisplayListBuilder builder,
                          const ShadowBox& box, float elevation,
                          const float color[4], float alpha,
                          float devicePixelRatio);

}  // namespace rni
