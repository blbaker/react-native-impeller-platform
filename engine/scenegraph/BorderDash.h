#pragma once
// Style audit items 10 + 25: borderStyle dashed / dotted.
//
// Geometry is RN iOS's (React/Views/RCTBorderDrawing.m,
// RCTGetDashedOrDottedBorderImage): ONE closed path along the border's centre
// line (the frame inset by half the width), built by RCTPathCreateWithRoundedRect
// (inverted=NO) clockwise from the top-left corner, stroked at the border width
// with a dash of on = off = 3 x width (dashed) or 1 x width (dotted), phase 0,
// butt caps, miter joins (CoreGraphics defaults).
//
// The dash phase is CONTINUOUS around the corners, which Impeller's
// DrawDashedLine (one segment, phase always 0) cannot express, so the dashes
// are walked here and each "on" run is filled as a rect. Where a dash runs
// through a corner the miter join fills the corner square. At the closing
// corner (top-left) the join is drawn when the dash is on at both the end of
// the path and its start (phase 0 is always on), as a closed subpath does.
//
// Scope: uniform width and colour on a SQUARE box. RN iOS also refuses mixed
// colours ("Unsupported dashed / dotted border style"). A rounded dashed
// border falls back to the solid rounded stroke; reported, not claimed.

#include <algorithm>
#include <cmath>

#include "impeller.h"

namespace rni {

// react::BorderStyle: 0 Solid, 1 Dotted, 2 Dashed.
inline float BorderDashOn(int style, float width) {
  if (style == 2) return 3.0f * width;
  if (style == 1) return 1.0f * width;
  return 0.0f;
}

// Returns true when it painted (non-solid style, positive width, room for it).
inline bool PaintDashedBorder(ImpellerDisplayListBuilder builder, int style,
                              float x, float y, float w, float h, float width,
                              ImpellerColor color) {
  const float on = BorderDashOn(style, width);
  if (on <= 0.0f || width <= 0.0f) return false;
  const float period = 2.0f * on, hw = width * 0.5f;
  const float x0 = x + hw, y0 = y + hw, x1 = x + w - hw, y1 = y + h - hw;
  if (x1 < x0 || y1 < y0) return false;  // border wider than the box

  ImpellerPaint paint = ImpellerPaintNew();
  ImpellerPaintSetColor(paint, &color);
  auto fill = [&](float ax, float ay, float bx, float by) {
    ImpellerRect r = {std::min(ax, bx), std::min(ay, by), std::fabs(bx - ax),
                      std::fabs(by - ay)};
    if (r.width > 0.0f && r.height > 0.0f) {
      ImpellerDisplayListBuilderDrawRect(builder, &r, paint);
    }
  };
  // Clockwise from the top-left, as RCTPathCreateWithRoundedRect builds it.
  struct Edge { float sx, sy, dx, dy, len; };
  const Edge edges[4] = {{x0, y0, 1, 0, x1 - x0},
                         {x1, y0, 0, 1, y1 - y0},
                         {x1, y1, -1, 0, x1 - x0},
                         {x0, y1, 0, -1, y1 - y0}};
  const float total = 2.0f * ((x1 - x0) + (y1 - y0));
  const float eps = 1e-3f;
  auto onAt = [&](float t) { return std::fmod(std::max(t, 0.0f), period) < on; };
  float T = 0.0f;  // distance along the path at the start of this edge
  for (int e = 0; e < 4; ++e) {
    const Edge& g = edges[e];
    for (float s = std::floor(T / period) * period; s < T + g.len; s += period) {
      const float a = std::max(s, T) - T, b = std::min(s + on, T + g.len) - T;
      if (b <= a) continue;
      const float ax = g.sx + g.dx * a, ay = g.sy + g.dy * a;
      const float bx = g.sx + g.dx * b, by = g.sy + g.dy * b;
      if (g.dy == 0.0f) fill(ax, ay - hw, bx, by + hw);  // horizontal edge
      else fill(ax - hw, ay, bx + hw, by);               // vertical edge
    }
    T += g.len;
    // Miter join at the corner this edge ends on, when a dash runs through it.
    const bool before = onAt(T - eps);
    const bool after = (e == 3) ? onAt(0.0f) : onAt(T + eps);
    if (before && after && total > 0.0f) {
      const Edge& n = edges[(e + 1) % 4];
      fill(n.sx - hw, n.sy - hw, n.sx + hw, n.sy + hw);
    }
  }
  ImpellerPaintRelease(paint);
  return true;
}

}  // namespace rni
