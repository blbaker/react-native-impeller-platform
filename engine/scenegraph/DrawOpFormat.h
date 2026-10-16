#pragma once
// FP-50: number/geometry formatting shared by the hook files. Floats print with at most 3
// decimals and no trailing zeros so a dump is stable across platforms and libm versions.
#include <cmath>
#include <cstdio>
#include <string>

#include "impeller.h"
#include "scenegraph/DrawOpLog.h"

namespace rni::drawop {

inline std::string N(float v) {
  if (!std::isfinite(v)) return std::isnan(v) ? "nan" : (v < 0 ? "-inf" : "inf");
  char buf[32];
  std::snprintf(buf, sizeof buf, "%.3f", (double)v);
  std::string s = buf;
  while (!s.empty() && s.back() == '0') s.pop_back();
  if (!s.empty() && s.back() == '.') s.pop_back();
  return s == "-0" ? "0" : s;
}

inline std::string Rect(const ImpellerRect* r) {
  if (!r) return "rect(null)";
  return "rect(" + N(r->x) + "," + N(r->y) + "," + N(r->width) + "," + N(r->height) + ")";
}
inline std::string Pt(const ImpellerPoint* p) { return p ? "(" + N(p->x) + "," + N(p->y) + ")" : "(null)"; }

inline std::string Color(const ImpellerColor* c) {
  if (!c) return "#null";
  auto byte = [](float v) { return (int)std::lround(std::fmin(std::fmax(v, 0.f), 1.f) * 255.f); };
  char buf[16];
  std::snprintf(buf, sizeof buf, "#%02x%02x%02x%02x", byte(c->red), byte(c->green), byte(c->blue),
                byte(c->alpha));
  return buf;
}

inline const char* BlendName(int mode) {
  static const char* const kNames[] = {
      "clear", "source", "destination", "source-over", "destination-over", "source-in", "destination-in",
      "source-out", "destination-out", "source-atop", "destination-atop", "xor", "plus", "modulate",
      "screen", "overlay", "darken", "lighten", "color-dodge", "color-burn", "hard-light", "soft-light",
      "difference", "exclusion", "multiply", "hue", "saturation", "color", "luminosity"};
  return mode >= 0 && mode < (int)(sizeof kNames / sizeof *kNames) ? kNames[mode] : "?";
}

inline std::string Corner(const ImpellerPoint& p) {
  return p.x == p.y ? N(p.x) : N(p.x) + "x" + N(p.y);
}
// "r=5" when every corner is the same circle, else the four corners.
inline std::string Radii(const ImpellerRoundingRadii* r) {
  if (!r) return "r(null)";
  const std::string tl = Corner(r->top_left), tr = Corner(r->top_right), br = Corner(r->bottom_right),
                    bl = Corner(r->bottom_left);
  if (tl == tr && tl == br && tl == bl) return "r=" + tl;
  return "r(tl=" + tl + " tr=" + tr + " br=" + br + " bl=" + bl + ")";
}

inline std::string Matrix(const ImpellerMatrix& m) {
  const float* f = m.m;
  const bool affine = f[2] == 0 && f[3] == 0 && f[6] == 0 && f[7] == 0 && f[8] == 0 && f[9] == 0 &&
                      f[10] == 1 && f[11] == 0 && f[14] == 0 && f[15] == 1;
  if (!affine) {
    std::string s = "m4[";
    for (int i = 0; i < 16; ++i) s += (i ? " " : "") + N(f[i]);
    return s + "]";
  }
  if (f[0] == 1 && f[1] == 0 && f[4] == 0 && f[5] == 1 && f[12] == 0 && f[13] == 0) return "I";
  return "[" + N(f[0]) + " " + N(f[1]) + " " + N(f[4]) + " " + N(f[5]) + " " + N(f[12]) + " " +
         N(f[13]) + "]";
}

inline void Grow(Box& b, float x, float y) {
  if (!b.bounded) {
    b = Box{true, x, y, x, y};
    return;
  }
  b.l = std::fmin(b.l, x);
  b.t = std::fmin(b.t, y);
  b.r = std::fmax(b.r, x);
  b.b = std::fmax(b.b, y);
}
inline void GrowRect(Box& b, const ImpellerRect& r) {
  Grow(b, r.x, r.y);
  Grow(b, r.x + r.width, r.y + r.height);
}

inline std::string BoxStr(const Box& b) {
  return b.bounded ? "(" + N(b.l) + "," + N(b.t) + "," + N(b.r) + "," + N(b.b) + ")" : "none";
}

}  // namespace rni::drawop
