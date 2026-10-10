#include "BorderDashRounded.h"

#include <algorithm>
#include <cmath>
#include <vector>

#include "scenegraph/BorderDash.h"

namespace rni {

namespace {

struct Seg { float ax, ay, bx, by, s0, len; int side; };

struct Outline {
  std::vector<Seg> segs;
  float total = 0.0f;
  float cornerS[4] = {0, 0, 0, 0};  // distance at the top-right, bottom-right, bottom-left, top-left corner
  float cornerX[4] = {0, 0, 0, 0}, cornerY[4] = {0, 0, 0, 0};
};

void AddLine(Outline& o, float ax, float ay, float bx, float by, int side) {
  const float len = std::hypot(bx - ax, by - ay);
  if (len <= 0.0f) return;
  o.segs.push_back({ax, ay, bx, by, o.total, len, side});
  o.total += len;
}

// Quarter ellipse about (cx, cy) from angle a0 to a0 + 90 degrees; the first
// half belongs to side `first`, the second half to `second`.
void AddArc(Outline& o, float cx, float cy, float rx, float ry, float a0, int first,
            int second) {
  if (rx <= 0.0f || ry <= 0.0f) return;
  const int n = std::max(8, (int)std::ceil(1.5708f * std::max(rx, ry) / 1.5f));
  float px = cx + rx * std::cos(a0), py = cy + ry * std::sin(a0);
  for (int i = 1; i <= n; ++i) {
    const float a = a0 + 1.5707963f * (float)i / (float)n;
    const float qx = cx + rx * std::cos(a), qy = cy + ry * std::sin(a);
    AddLine(o, px, py, qx, qy, i * 2 <= n ? first : second);
    px = qx; py = qy;
  }
}

Outline BuildOutline(float x0, float y0, float x1, float y1, float hw,
                     const ImpellerRoundingRadii& rr) {
  auto cx = [&](ImpellerPoint r) { return std::max(0.0f, r.x - hw); };
  auto cy = [&](ImpellerPoint r) { return std::max(0.0f, r.y - hw); };
  const float tlx = cx(rr.top_left), tly = cy(rr.top_left);
  const float trx = cx(rr.top_right), try_ = cy(rr.top_right);
  const float brx = cx(rr.bottom_right), bry = cy(rr.bottom_right);
  const float blx = cx(rr.bottom_left), bly = cy(rr.bottom_left);
  Outline o;
  const float half = 1.5707963f;
  AddLine(o, x0 + tlx, y0, x1 - trx, y0, 0);
  o.cornerS[0] = o.total; o.cornerX[0] = x1; o.cornerY[0] = y0;
  AddArc(o, x1 - trx, y0 + try_, trx, try_, -half, 0, 1);
  AddLine(o, x1, y0 + try_, x1, y1 - bry, 1);
  o.cornerS[1] = o.total; o.cornerX[1] = x1; o.cornerY[1] = y1;
  AddArc(o, x1 - brx, y1 - bry, brx, bry, 0.0f, 1, 2);
  AddLine(o, x1 - brx, y1, x0 + blx, y1, 2);
  o.cornerS[2] = o.total; o.cornerX[2] = x0; o.cornerY[2] = y1;
  AddArc(o, x0 + blx, y1 - bly, blx, bly, half, 2, 3);
  AddLine(o, x0, y1 - bly, x0, y0 + tly, 3);
  o.cornerS[3] = o.total; o.cornerX[3] = x0; o.cornerY[3] = y0;
  AddArc(o, x0 + tlx, y0 + tly, tlx, tly, 2.0f * half, 3, 0);
  return o;
}

struct Stroker {
  ImpellerDisplayListBuilder builder;
  float width;
  const ImpellerColor* colors;
  const bool* visible;
  ImpellerPathBuilder pb = nullptr;
  int side = -1;

  void Flush() {
    if (pb == nullptr) return;
    ImpellerPath path = ImpellerPathBuilderTakePathNew(pb, kImpellerFillTypeNonZero);
    ImpellerPathBuilderRelease(pb);
    pb = nullptr;
    if (path == nullptr) return;
    ImpellerPaint paint = ImpellerPaintNew();
    ImpellerColor c = colors[side];
    ImpellerPaintSetColor(paint, &c);
    ImpellerPaintSetDrawStyle(paint, kImpellerDrawStyleStroke);
    ImpellerPaintSetStrokeWidth(paint, width);
    ImpellerPaintSetStrokeCap(paint, kImpellerStrokeCapButt);
    ImpellerPaintSetStrokeJoin(paint, kImpellerStrokeJoinRound);
    ImpellerDisplayListBuilderDrawPath(builder, path, paint);
    ImpellerPaintRelease(paint);
    ImpellerPathRelease(path);
  }

  void Piece(const Seg& g, float a, float b) {  // a, b: distances inside g
    if (!visible[g.side]) { Flush(); side = -1; return; }
    const float ux = (g.bx - g.ax) / g.len, uy = (g.by - g.ay) / g.len;
    ImpellerPoint p = {g.ax + ux * a, g.ay + uy * a};
    ImpellerPoint q = {g.ax + ux * b, g.ay + uy * b};
    if (pb == nullptr || side != g.side) {
      Flush();
      pb = ImpellerPathBuilderNew();
      side = g.side;
      ImpellerPathBuilderMoveTo(pb, &p);
    }
    ImpellerPathBuilderLineTo(pb, &q);
  }
};

}  // namespace

bool PaintDashedRoundedBorder(ImpellerDisplayListBuilder builder, int style, float x,
                              float y, float w, float h, float width,
                              const ImpellerColor colors[4], const bool visible[4],
                              const ImpellerRoundingRadii& radii) {
  const float on = BorderDashOn(style, width);
  if (on <= 0.0f || width <= 0.0f) return false;
  const float hw = width * 0.5f;
  const float x0 = x + hw, y0 = y + hw, x1 = x + w - hw, y1 = y + h - hw;
  if (x1 <= x0 || y1 <= y0) return false;
  const Outline o = BuildOutline(x0, y0, x1, y1, hw, radii);
  if (o.segs.empty()) return false;
  const float period = 2.0f * on;

  Stroker st{builder, width, colors, visible};
  for (float s = 0.0f; s < o.total; s += period) {
    const float a = s, b = std::min(s + on, o.total);
    st.side = -1;
    for (const Seg& g : o.segs) {
      const float lo = std::max(a, g.s0), hi = std::min(b, g.s0 + g.len);
      if (hi > lo) st.Piece(g, lo - g.s0, hi - g.s0);
    }
    st.Flush();
  }

  // A square corner (radius 0) that a dash runs through needs the corner square;
  // butt caps leave it empty. It takes the colour of the edge that follows.
  const float r[4] = {radii.top_right.x, radii.bottom_right.x, radii.bottom_left.x,
                      radii.top_left.x};
  for (int c = 0; c < 4; ++c) {
    const int next = (c + 1) % 4;
    if (r[c] > hw || !visible[next]) continue;
    const float m = std::fmod(c == 3 ? 0.0f : o.cornerS[c], period);
    if (m >= on) continue;
    ImpellerPaint paint = ImpellerPaintNew();
    ImpellerColor col = colors[next];
    ImpellerPaintSetColor(paint, &col);
    ImpellerRect rc = {o.cornerX[c] - hw, o.cornerY[c] - hw, width, width};
    ImpellerDisplayListBuilderDrawRect(builder, &rc, paint);
    ImpellerPaintRelease(paint);
  }
  return true;
}

}  // namespace rni
