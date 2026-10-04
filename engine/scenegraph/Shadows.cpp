#include "scenegraph/Shadows.h"

#include <algorithm>
#include <cmath>

namespace rni {

namespace {

ImpellerColor ToColor(const float c[4], float alpha) {
  return ImpellerColor{c[0], c[1], c[2], c[3] * alpha, kImpellerColorSpaceSRGB};
}

// CSS spread on a rounded box: a corner radius r grows by the spread s, but a
// SHARP corner must stay sharp-ish. Same rule RN iOS uses
// (RCTBoxShadow.mm adjustedCornerRadius): when r < |s| the adjustment is
// scaled by (1 + (r/|s| - 1)^3).
float SpreadRadius(float r, float s) {
  if (r <= 0.0f) return 0.0f;
  float adj = s;
  const float as = std::fabs(s);
  if (r < as) {
    const float k = r / as;
    adj *= 1.0f + (k - 1.0f) * (k - 1.0f) * (k - 1.0f);
  }
  return std::max(0.0f, r + adj);
}

ImpellerRoundingRadii SpreadRadii(const ImpellerRoundingRadii& r, float s) {
  ImpellerRoundingRadii o;
  o.top_left = {SpreadRadius(r.top_left.x, s), SpreadRadius(r.top_left.y, s)};
  o.bottom_left = {SpreadRadius(r.bottom_left.x, s), SpreadRadius(r.bottom_left.y, s)};
  o.top_right = {SpreadRadius(r.top_right.x, s), SpreadRadius(r.top_right.y, s)};
  o.bottom_right = {SpreadRadius(r.bottom_right.x, s), SpreadRadius(r.bottom_right.y, s)};
  return o;
}

bool AnyRadius(const ImpellerRoundingRadii& r) {
  return r.top_left.x > 0 || r.top_left.y > 0 || r.bottom_left.x > 0 ||
         r.bottom_left.y > 0 || r.top_right.x > 0 || r.top_right.y > 0 ||
         r.bottom_right.x > 0 || r.bottom_right.y > 0;
}

void ClipBox(ImpellerDisplayListBuilder builder, const ImpellerRect& rect,
             const ImpellerRoundingRadii& radii, ImpellerClipOperation op) {
  if (AnyRadius(radii)) {
    ImpellerDisplayListBuilderClipRoundedRect(builder, &rect, &radii, op);
  } else {
    ImpellerDisplayListBuilderClipRect(builder, &rect, op);
  }
}

ImpellerPaint ShadowPaint(const ShadowSpec& s, float alpha) {
  ImpellerPaint p = ImpellerPaintNew();
  const ImpellerColor c = ToColor(s.color, alpha);
  ImpellerPaintSetColor(p, &c);
  if (s.sigma > 0.0f) {
    ImpellerMaskFilter mf = ImpellerMaskFilterCreateBlurNew(kImpellerBlurStyleNormal, s.sigma);
    if (mf != nullptr) {
      ImpellerPaintSetMaskFilter(p, mf);
      ImpellerMaskFilterRelease(mf);
    }
  }
  return p;
}

}  // namespace

void PaintOuterShadows(ImpellerDisplayListBuilder builder, const ShadowBox& box,
                       const std::vector<ShadowSpec>& shadows, float alpha) {
  // CSS paints the list back to front: the FIRST shadow is on top.
  for (auto it = shadows.rbegin(); it != shadows.rend(); ++it) {
    const ShadowSpec& s = *it;
    if (s.inset || s.color[3] * alpha <= 0.0f) continue;
    const ImpellerRect border = {box.x, box.y, box.w, box.h};
    ImpellerDisplayListBuilderSave(builder);
    if (s.clipOutsideBox) {
      ClipBox(builder, border, box.radii, kImpellerClipOperationDifference);
    }
    const ImpellerRect shape = {box.x + s.offsetX - s.spread, box.y + s.offsetY - s.spread,
                                box.w + 2.0f * s.spread, box.h + 2.0f * s.spread};
    if (shape.width > 0.0f && shape.height > 0.0f) {
      ImpellerPaint p = ShadowPaint(s, alpha);
      const ImpellerRoundingRadii r = SpreadRadii(box.radii, s.spread);
      if (AnyRadius(r)) {
        ImpellerDisplayListBuilderDrawRoundedRect(builder, &shape, &r, p);
      } else {
        ImpellerDisplayListBuilderDrawRect(builder, &shape, p);
      }
      ImpellerPaintRelease(p);
    }
    ImpellerDisplayListBuilderRestore(builder);
  }
}

void PaintInsetShadows(ImpellerDisplayListBuilder builder, const ShadowBox& box,
                       const float bw[4], const std::vector<ShadowSpec>& shadows,
                       float alpha) {
  // Padding box = border box minus the border widths (t, r, b, l).
  const ImpellerRect pad = {box.x + bw[3], box.y + bw[0],
                            std::max(0.0f, box.w - bw[1] - bw[3]),
                            std::max(0.0f, box.h - bw[0] - bw[2])};
  if (pad.width <= 0.0f || pad.height <= 0.0f) return;
  // Inner radii follow the CSS rule: outer radius minus the adjacent border.
  ImpellerRoundingRadii padR;
  padR.top_left = {std::max(0.0f, box.radii.top_left.x - bw[3]),
                   std::max(0.0f, box.radii.top_left.y - bw[0])};
  padR.top_right = {std::max(0.0f, box.radii.top_right.x - bw[1]),
                    std::max(0.0f, box.radii.top_right.y - bw[0])};
  padR.bottom_left = {std::max(0.0f, box.radii.bottom_left.x - bw[3]),
                      std::max(0.0f, box.radii.bottom_left.y - bw[2])};
  padR.bottom_right = {std::max(0.0f, box.radii.bottom_right.x - bw[1]),
                       std::max(0.0f, box.radii.bottom_right.y - bw[2])};

  for (auto it = shadows.rbegin(); it != shadows.rend(); ++it) {
    const ShadowSpec& s = *it;
    if (!s.inset || s.color[3] * alpha <= 0.0f) continue;
    ImpellerDisplayListBuilderSave(builder);
    ClipBox(builder, pad, padR, kImpellerClipOperationIntersect);
    // The shadow is everything OUTSIDE the "hole": the padding box moved by
    // the offset and shrunk by the spread. The outer edge is pushed past the
    // clip by the blur extent plus the offset so the blur never shows an
    // edge of its own inside the box.
    const float reach = 3.0f * s.sigma + std::fabs(s.offsetX) + std::fabs(s.offsetY) +
                        std::fabs(s.spread) + 1.0f;
    const ImpellerRect outer = {pad.x - reach, pad.y - reach, pad.width + 2.0f * reach,
                                pad.height + 2.0f * reach};
    ImpellerRect hole = {pad.x + s.offsetX + s.spread, pad.y + s.offsetY + s.spread,
                         pad.width - 2.0f * s.spread, pad.height - 2.0f * s.spread};
    ImpellerPaint p = ShadowPaint(s, alpha);
    const ImpellerRoundingRadii none{};
    if (hole.width <= 0.0f || hole.height <= 0.0f) {
      // Spread swallowed the box: the whole padding box is shadow.
      ImpellerDisplayListBuilderDrawRect(builder, &outer, p);
    } else {
      const ImpellerRoundingRadii holeR = SpreadRadii(padR, -s.spread);
      ImpellerDisplayListBuilderDrawRoundedRectDifference(builder, &outer, &none, &hole,
                                                          &holeR, p);
    }
    ImpellerPaintRelease(p);
    ImpellerDisplayListBuilderRestore(builder);
  }
}

void PaintElevationShadow(ImpellerDisplayListBuilder builder, const ShadowBox& box,
                          float elevation, const float color[4], float alpha,
                          float devicePixelRatio) {
  if (elevation <= 0.0f || color[3] * alpha <= 0.0f) return;
  ImpellerPathBuilder pb = ImpellerPathBuilderNew();
  if (pb == nullptr) return;
  const ImpellerRect r = {box.x, box.y, box.w, box.h};
  if (AnyRadius(box.radii)) {
    ImpellerPathBuilderAddRoundedRect(pb, &r, &box.radii);
  } else {
    ImpellerPathBuilderAddRect(pb, &r);
  }
  ImpellerPath path = ImpellerPathBuilderTakePathNew(pb, kImpellerFillTypeNonZero);
  ImpellerPathBuilderRelease(pb);
  if (path == nullptr) return;
  const ImpellerColor c = ToColor(color, alpha);
  // Material shadows (ambient + key light), the model Android elevation uses.
  // occluder_is_transparent=false: the box itself paints over the umbra.
  ImpellerDisplayListBuilderDrawShadow(builder, path, &c, elevation, false,
                                       devicePixelRatio > 0.0f ? devicePixelRatio : 1.0f);
  ImpellerPathRelease(path);
}

}  // namespace rni
