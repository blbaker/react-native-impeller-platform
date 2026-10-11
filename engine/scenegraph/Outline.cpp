#include "Outline.h"

#include <algorithm>

#include "scenegraph/BorderDashRounded.h"

namespace rni {

namespace {

ImpellerPoint Grow(ImpellerPoint r, float d) {
  if (r.x <= 0.0f && r.y <= 0.0f) return {0.0f, 0.0f};
  return {std::max(0.0f, r.x + d), std::max(0.0f, r.y + d)};
}

ImpellerRoundingRadii GrowRadii(const ImpellerRoundingRadii& r, float d) {
  ImpellerRoundingRadii o = r;
  o.top_left = Grow(r.top_left, d);
  o.bottom_left = Grow(r.bottom_left, d);
  o.top_right = Grow(r.top_right, d);
  o.bottom_right = Grow(r.bottom_right, d);
  return o;
}

}  // namespace

void PaintOutline(ImpellerDisplayListBuilder builder, float x, float y, float w, float h,
                  const ImpellerRoundingRadii& radii, float width, float offset,
                  int style, const ImpellerColor& color) {
  if (width <= 0.0f || color.alpha <= 0.0f) return;
  const float grow = offset + width;  // outer edge of the ring, from the box edge
  const float ow = w + 2.0f * grow, oh = h + 2.0f * grow;
  if (ow <= 0.0f || oh <= 0.0f) return;
  const ImpellerRoundingRadii outer = GrowRadii(radii, grow);
  if (style != 0) {
    const ImpellerColor cols[4] = {color, color, color, color};
    const bool vis[4] = {true, true, true, true};
    if (PaintDashedRoundedBorder(builder, style, x - grow, y - grow, ow, oh, width, cols,
                                 vis, outer)) {
      return;
    }
  }
  ImpellerPaint paint = ImpellerPaintNew();
  ImpellerPaintSetColor(paint, &color);
  ImpellerPaintSetDrawStyle(paint, kImpellerDrawStyleStroke);
  ImpellerPaintSetStrokeWidth(paint, width);
  const float half = width * 0.5f;
  const ImpellerRect rect = {x - grow + half, y - grow + half, ow - width, oh - width};
  const ImpellerRoundingRadii mid = GrowRadii(outer, -half);
  ImpellerDisplayListBuilderDrawRoundedRect(builder, &rect, &mid, paint);
  ImpellerPaintRelease(paint);
}

}  // namespace rni
