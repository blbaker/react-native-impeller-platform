#include "scenegraph/ActivityIndicator.h"

#include <algorithm>

namespace rni {

namespace {
constexpr float kMinAlpha = 0.15f;
}  // namespace

void PaintActivityIndicator(ImpellerDisplayListBuilder builder, float x, float y, float w,
                            float h, const ImpellerColor& color, int step) {
  const float size = std::min(w, h);
  if (size <= 0.0f) return;
  const float outer = size * 0.5f;
  const float inner = outer * 0.58f;
  const float thick = std::max(size * 0.085f, 1.0f);
  ImpellerPaint paint = ImpellerPaintNew();
  ImpellerDisplayListBuilderSave(builder);
  ImpellerDisplayListBuilderTranslate(builder, x + w * 0.5f, y + h * 0.5f);
  for (int i = 0; i < kSpinnerSpokes; ++i) {
    // k = how many spokes behind the head this one is; clockwise rotation.
    const int k = ((step - i) % kSpinnerSpokes + kSpinnerSpokes) % kSpinnerSpokes;
    const float fade = 1.0f - static_cast<float>(k) / (kSpinnerSpokes - 1) * (1.0f - kMinAlpha);
    ImpellerColor c = color;
    c.alpha = color.alpha * fade;
    ImpellerPaintSetColor(paint, &c);
    ImpellerDisplayListBuilderSave(builder);
    ImpellerDisplayListBuilderRotate(builder, 30.0f * static_cast<float>(i));
    const ImpellerRect spoke = {-thick * 0.5f, -outer, thick, outer - inner};
    ImpellerRoundingRadii r = {};
    r.top_left = r.top_right = r.bottom_left = r.bottom_right = {thick * 0.5f, thick * 0.5f};
    ImpellerDisplayListBuilderDrawRoundedRect(builder, &spoke, &r, paint);
    ImpellerDisplayListBuilderRestore(builder);
  }
  ImpellerDisplayListBuilderRestore(builder);
  ImpellerPaintRelease(paint);
}

}  // namespace rni
