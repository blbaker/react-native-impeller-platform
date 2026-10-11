#include "scenegraph/ScrollIndicators.h"

#include <algorithm>

namespace rni {

namespace {

constexpr float kThickness = 3.0f;
constexpr float kInset = 2.0f;
constexpr float kMinLength = 8.0f;

ImpellerColor IndicatorColor(int style) {
  if (style == 2) return {1.0f, 1.0f, 1.0f, 0.5f};
  return {0.0f, 0.0f, 0.0f, style == 1 ? 0.5f : 0.35f};
}

// Returns the bar's [start, length] along a track of `track` px.
void BarSpan(float viewport, float content, float offset, float track, float* start, float* len) {
  const float maxOffset = std::max(content - viewport, 0.0f);
  *len = std::min(track, std::max(kMinLength, track * viewport / content));
  const float t = maxOffset > 0.0f ? std::min(std::max(offset / maxOffset, 0.0f), 1.0f) : 0.0f;
  *start = (track - *len) * t;
}

void DrawBar(ImpellerDisplayListBuilder builder, const ImpellerRect& r, int style) {
  ImpellerPaint paint = ImpellerPaintNew();
  const ImpellerColor c = IndicatorColor(style);
  ImpellerPaintSetColor(paint, &c);
  const float rad = kThickness * 0.5f;
  const ImpellerRoundingRadii radii = {{rad, rad}, {rad, rad}, {rad, rad}, {rad, rad}};
  ImpellerDisplayListBuilderDrawRoundedRect(builder, &r, &radii, paint);
  ImpellerPaintRelease(paint);
}

}  // namespace

void PaintScrollIndicators(ImpellerDisplayListBuilder builder, const ScrollIndicatorSpec& s) {
  const bool vert = s.showVertical && s.contentH > s.h + 0.5f && s.h > 0.0f;
  const bool horiz = s.showHorizontal && s.contentW > s.w + 0.5f && s.w > 0.0f;
  // Leave the corner free when both bars are present.
  const float corner = (vert && horiz) ? kThickness + kInset : 0.0f;
  if (vert) {
    const float track = std::max(s.h - 2.0f * kInset - corner, 0.0f);
    float start = 0.0f, len = 0.0f;
    BarSpan(s.h, s.contentH, s.scrollY, track, &start, &len);
    const ImpellerRect r = {s.x + s.w - kInset - kThickness, s.y + kInset + start, kThickness, len};
    DrawBar(builder, r, s.style);
  }
  if (horiz) {
    const float track = std::max(s.w - 2.0f * kInset - corner, 0.0f);
    float start = 0.0f, len = 0.0f;
    BarSpan(s.w, s.contentW, s.scrollX, track, &start, &len);
    const ImpellerRect r = {s.x + kInset + start, s.y + s.h - kInset - kThickness, len, kThickness};
    DrawBar(builder, r, s.style);
  }
}

}  // namespace rni
