#include "BorderCurve.h"

namespace rni {

namespace {

// iOS continuous corner as 3 cubics, in units of the radius: {a, b} where a runs
// along the incoming edge (distance from the corner) and b runs along the
// outgoing edge. Marc Edwards' iOS 7 rounded-rect construction.
constexpr float kExt = 1.52866483f;
constexpr float kCurve[10][2] = {
    {1.52866483f, 0.0f},        {1.08849323f, 0.0f},        {0.86840694f, 0.0f},
    {0.63149379f, 0.07491139f}, {0.37282383f, 0.16905956f}, {0.16905956f, 0.37282383f},
    {0.07491139f, 0.63149379f}, {0.0f, 0.86840694f},        {0.0f, 1.08849323f},
    {0.0f, 1.52866483f},
};

struct Corner {
  float cx, cy;    // the box corner
  float ix, iy;    // inward direction on each axis
  float rx, ry;
  bool swap;       // incoming edge is vertical
};

void AddCorner(ImpellerPathBuilder pb, const Corner& c, bool first) {
  auto pt = [&](int i) {
    const float a = kCurve[i][0] / kExt, b = kCurve[i][1] / kExt;
    const float dx = c.swap ? b : a, dy = c.swap ? a : b;
    return ImpellerPoint{c.cx + c.ix * dx * c.rx, c.cy + c.iy * dy * c.ry};
  };
  ImpellerPoint p0 = pt(0);
  if (first) ImpellerPathBuilderMoveTo(pb, &p0);
  else ImpellerPathBuilderLineTo(pb, &p0);
  for (int i = 1; i < 10; i += 3) {
    ImpellerPoint c1 = pt(i), c2 = pt(i + 1), e = pt(i + 2);
    ImpellerPathBuilderCubicCurveTo(pb, &c1, &c2, &e);
  }
}

}  // namespace

ImpellerPath MakeContinuousRRectPath(float x, float y, float w, float h,
                                     const ImpellerRoundingRadii& r) {
  const Corner corners[4] = {
      {x + w, y, -1, 1, r.top_right.x, r.top_right.y, false},
      {x + w, y + h, -1, -1, r.bottom_right.x, r.bottom_right.y, true},
      {x, y + h, 1, -1, r.bottom_left.x, r.bottom_left.y, false},
      {x, y, 1, 1, r.top_left.x, r.top_left.y, true},
  };
  ImpellerPathBuilder pb = ImpellerPathBuilderNew();
  for (int i = 0; i < 4; ++i) AddCorner(pb, corners[i], i == 0);
  ImpellerPathBuilderClose(pb);
  ImpellerPath path = ImpellerPathBuilderTakePathNew(pb, kImpellerFillTypeNonZero);
  ImpellerPathBuilderRelease(pb);
  return path;
}

}  // namespace rni
