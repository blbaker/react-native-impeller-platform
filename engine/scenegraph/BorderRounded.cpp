#include "BorderRounded.h"

#include <algorithm>

namespace rni {

namespace {

ImpellerPath WedgePath(const float px[4], const float py[4]) {
  ImpellerPathBuilder pb = ImpellerPathBuilderNew();
  ImpellerPoint p0 = {px[0], py[0]};
  ImpellerPathBuilderMoveTo(pb, &p0);
  for (int k = 1; k < 4; ++k) {
    ImpellerPoint p = {px[k], py[k]};
    ImpellerPathBuilderLineTo(pb, &p);
  }
  ImpellerPathBuilderClose(pb);
  ImpellerPath path = ImpellerPathBuilderTakePathNew(pb, kImpellerFillTypeNonZero);
  ImpellerPathBuilderRelease(pb);
  return path;
}

ImpellerPoint ShrinkRadius(ImpellerPoint r, float dx, float dy) {
  return {std::max(0.0f, r.x - dx), std::max(0.0f, r.y - dy)};
}

}  // namespace

void PaintRoundedMixedBorder(ImpellerDisplayListBuilder builder, float x, float y,
                             float w, float h, const float widths[4],
                             const ImpellerColor colors[4], const bool visible[4],
                             const ImpellerRoundingRadii& radii) {
  const float t = widths[0], r = widths[1], b = widths[2], l = widths[3];
  const float ox0 = x, oy0 = y, ox1 = x + w, oy1 = y + h;
  const float ix0 = x + l, iy0 = y + t, ix1 = x + w - r, iy1 = y + h - b;

  ImpellerDisplayListBuilderSave(builder);
  ImpellerRect outer = {x, y, w, h};
  ImpellerDisplayListBuilderClipRoundedRect(builder, &outer, &radii,
                                            kImpellerClipOperationIntersect);
  if (ix1 > ix0 && iy1 > iy0) {
    ImpellerRect inner = {ix0, iy0, ix1 - ix0, iy1 - iy0};
    ImpellerRoundingRadii ir;
    ir.top_left = ShrinkRadius(radii.top_left, l, t);
    ir.top_right = ShrinkRadius(radii.top_right, r, t);
    ir.bottom_right = ShrinkRadius(radii.bottom_right, r, b);
    ir.bottom_left = ShrinkRadius(radii.bottom_left, l, b);
    ImpellerDisplayListBuilderClipRoundedRect(builder, &inner, &ir,
                                              kImpellerClipOperationDifference);
  }

  const float px[4][4] = {{ox0, ox1, ix1, ix0}, {ox1, ox1, ix1, ix1},
                          {ox1, ox0, ix0, ix1}, {ox0, ox0, ix0, ix0}};
  const float py[4][4] = {{oy0, oy0, iy0, iy0}, {oy0, oy1, iy1, iy0},
                          {oy1, oy1, iy1, iy1}, {oy1, oy0, iy0, iy1}};
  for (int e = 0; e < 4; ++e) {
    if (widths[e] <= 0.0f || !visible[e]) continue;
    ImpellerPath wedge = WedgePath(px[e], py[e]);
    if (wedge == nullptr) continue;
    ImpellerDisplayListBuilderSave(builder);
    ImpellerDisplayListBuilderClipPath(builder, wedge, kImpellerClipOperationIntersect);
    ImpellerPaint paint = ImpellerPaintNew();
    ImpellerPaintSetColor(paint, &colors[e]);
    ImpellerDisplayListBuilderDrawRect(builder, &outer, paint);
    ImpellerPaintRelease(paint);
    ImpellerDisplayListBuilderRestore(builder);
    ImpellerPathRelease(wedge);
  }
  ImpellerDisplayListBuilderRestore(builder);
}

}  // namespace rni
