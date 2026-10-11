#include "BackgroundLayers.h"

#include <algorithm>
#include <cmath>

namespace rni {

namespace react = facebook::react;

namespace {

using Rgba = std::array<float, 4>;

struct RawStop {
  bool hint;
  float pos;  // NaN when the author did not place the stop
  Rgba color;
};

// Stop position as a 0..1 fraction of `refLen`; NaN when unset.
float StopPos(const react::ValueUnit& v, float refLen) {
  if (v.unit == react::UnitType::Percent) return v.value / 100.0f;
  if (v.unit == react::UnitType::Point && refLen > 0.0f) return v.value / refLen;
  return std::nanf("");
}

// CSS stop fix-up: first defaults to 0, last to 1, positions never go
// backwards, and unplaced runs spread evenly between their neighbours.
void FixPositions(std::vector<RawStop>& s) {
  if (std::isnan(s.front().pos)) s.front().pos = 0.0f;
  if (std::isnan(s.back().pos)) s.back().pos = 1.0f;
  float prev = s.front().pos;
  for (auto& r : s) {
    if (std::isnan(r.pos)) continue;
    r.pos = std::max(r.pos, prev);
    prev = r.pos;
  }
  for (size_t i = 1; i + 1 < s.size(); ++i) {
    if (!std::isnan(s[i].pos)) continue;
    size_t j = i;
    while (std::isnan(s[j].pos)) ++j;
    const float a = s[i - 1].pos, b = s[j].pos;
    for (size_t k = i; k < j; ++k) {
      s[k].pos = a + (b - a) * (float)(k - i + 1) / (float)(j - i + 1);
    }
    i = j;
  }
}

// CSS interpolation hint between stops a and b: the colour mix at progress t
// is weighted by t^(ln 0.5 / ln H), H being the hint's place inside [a, b].
// Emitted as sampled stops since Impeller only interpolates linearly.
void AppendHint(BgLayer& L, const RawStop& a, const RawStop& b, float hintPos) {
  const float span = b.pos - a.pos;
  if (span <= 0.0f) return;
  const float h = (hintPos - a.pos) / span;
  if (h <= 0.001f || h >= 0.999f) return;
  const float expo = std::log(0.5f) / std::log(h);
  constexpr int kSamples = 24;
  for (int i = 1; i < kSamples; ++i) {
    const float t = (float)i / (float)kSamples;
    const float w = std::pow(t, expo);
    const float aa = a.color[3] * (1.0f - w), ba = b.color[3] * w;
    const float alpha = aa + ba;
    Rgba c{0, 0, 0, alpha};
    if (alpha > 0.0f) {
      for (int k = 0; k < 3; ++k) c[k] = (a.color[k] * aa + b.color[k] * ba) / alpha;
    }
    L.stops.push_back(a.pos + span * t);
    L.colors.push_back(c);
  }
}

// RN marks a colour hint as a stop with no colour but a position. Colour 0 is
// RN's "undefined", so transparent black reads the same: only a placed,
// interior, colourless entry counts as a hint (a placed `rgba(0,0,0,0) 50%`
// mid-gradient stop is indistinguishable and reads as a hint too).
bool BuildStops(const std::vector<react::ColorStop>& in, float refLen, BgLayer& L) {
  std::vector<RawStop> s;
  for (size_t i = 0; i < in.size(); ++i) {
    const auto& st = in[i];
    const float pos = StopPos(st.position, refLen);
    const bool interior = i > 0 && i + 1 < in.size();
    RawStop r{!st.color && interior && !std::isnan(pos), pos, {0, 0, 0, 0}};
    if (st.color) {
      auto c = react::colorComponentsFromColor(st.color);
      r.color = {c.red, c.green, c.blue, c.alpha};
    }
    s.push_back(r);
  }
  const auto isStop = [](const RawStop& r) { return !r.hint; };
  if (std::count_if(s.begin(), s.end(), isStop) < 2) return false;
  FixPositions(s);
  const RawStop* last = nullptr;
  for (size_t i = 0; i < s.size(); ++i) {
    if (s[i].hint) {
      if (last != nullptr && !s[i + 1].hint) AppendHint(L, *last, s[i + 1], s[i].pos);
      continue;
    }
    L.stops.push_back(std::clamp(s[i].pos, 0.0f, 1.0f));
    L.colors.push_back(s[i].color);
    last = &s[i];
  }
  return true;
}

BgLayer LinearLayer(const react::LinearGradient& lg, float w, float h) {
  BgLayer L;
  float angleRad = 0.0f;
  if (std::holds_alternative<react::Float>(lg.direction)) {
    angleRad = (float)std::get<react::Float>(lg.direction) * (float)M_PI / 180.0f;
  } else {
    switch (std::get<react::GradientKeyword>(lg.direction)) {
      case react::GradientKeyword::ToTopRight:    angleRad = 0.25f * (float)M_PI; break;
      case react::GradientKeyword::ToBottomRight: angleRad = 0.75f * (float)M_PI; break;
      case react::GradientKeyword::ToBottomLeft:  angleRad = 1.25f * (float)M_PI; break;
      case react::GradientKeyword::ToTopLeft:     angleRad = 1.75f * (float)M_PI; break;
    }
  }
  // The gradient line runs through the centre; y is negated because CSS angles
  // measure from "up" and our y axis grows downward.
  const float dx = std::sin(angleRad), dy = -std::cos(angleRad);
  const float half = (std::fabs(w * dx) + std::fabs(h * dy)) * 0.5f;
  const float cx = w * 0.5f, cy = h * 0.5f;
  L.start[0] = cx - dx * half;
  L.start[1] = cy - dy * half;
  L.end[0] = cx + dx * half;
  L.end[1] = cy + dy * half;
  if (!BuildStops(lg.colorStops, half * 2.0f, L)) L.stops.clear();
  return L;
}

// Centre offset along one axis from top/left or bottom/right.
float AxisCenter(const std::optional<react::ValueUnit>& from0,
                 const std::optional<react::ValueUnit>& from1, float len) {
  if (from0) return from0->resolve(len);
  if (from1) return len - from1->resolve(len);
  return len * 0.5f;
}

void RadialRadii(const react::RadialGradient& rg, float w, float h, BgLayer& L) {
  const float cx = L.center[0], cy = L.center[1];
  const float sideX[2] = {cx, w - cx}, sideY[2] = {cy, h - cy};
  const bool circle = rg.shape == react::RadialGradientShape::Circle;
  using Kw = react::RadialGradientSize::SizeKeyword;
  if (const auto* dim = std::get_if<react::RadialGradientSize::Dimensions>(&rg.size.value)) {
    L.rx = dim->x.resolve(w);
    L.ry = circle ? L.rx : dim->y.resolve(h);
    return;
  }
  Kw kw = Kw::FarthestCorner;
  if (const auto* k = std::get_if<Kw>(&rg.size.value)) kw = *k;
  const bool closest = (kw == Kw::ClosestSide || kw == Kw::ClosestCorner);
  const bool corner = (kw == Kw::ClosestCorner || kw == Kw::FarthestCorner);
  const float sx = closest ? std::min(sideX[0], sideX[1]) : std::max(sideX[0], sideX[1]);
  const float sy = closest ? std::min(sideY[0], sideY[1]) : std::max(sideY[0], sideY[1]);
  if (!corner) {
    L.rx = circle ? (closest ? std::min(sx, sy) : std::max(sx, sy)) : sx;
    L.ry = circle ? L.rx : sy;
    return;
  }
  if (circle) {  // the nearest/farthest corner sits at (sx, sy) from the centre
    L.rx = L.ry = std::sqrt(sx * sx + sy * sy);
    return;
  }
  // The ellipse keeps the side ellipse's aspect ratio and passes through the corner.
  const float k = (sx > 0.0f && sy > 0.0f) ? std::sqrt(2.0f) : 0.0f;
  L.rx = sx * k;
  L.ry = sy * k;
}

BgLayer RadialLayer(const react::RadialGradient& rg, float w, float h) {
  BgLayer L;
  L.radial = true;
  L.center[0] = AxisCenter(rg.position.left, rg.position.right, w);
  L.center[1] = AxisCenter(rg.position.top, rg.position.bottom, h);
  RadialRadii(rg, w, h, L);
  if (L.rx <= 0.0f || L.ry <= 0.0f || !BuildStops(rg.colorStops, L.rx, L)) L.stops.clear();
  return L;
}

template <typename T>
const T* Cycled(const std::vector<T>& v, size_t i) {
  return v.empty() ? nullptr : &v[i % v.size()];
}

}  // namespace

std::vector<BgLayer> BuildBackgroundLayers(const std::vector<react::BackgroundImage>& images,
                                           const std::vector<react::BackgroundSize>& sizes,
                                           const std::vector<react::BackgroundPosition>& positions,
                                           const std::vector<react::BackgroundRepeat>& repeats,
                                           float w, float h) {
  std::vector<BgLayer> out;
  for (size_t i = 0; i < images.size(); ++i) {
    const auto& image = images[i];
    BgTiling tiling = ComputeTiling(Cycled(sizes, i), Cycled(positions, i), Cycled(repeats, i), w, h);
    const float tw = tiling.tw, th = tiling.th;
    BgLayer L = std::holds_alternative<react::LinearGradient>(image)
                    ? LinearLayer(std::get<react::LinearGradient>(image), tw, th)
                    : RadialLayer(std::get<react::RadialGradient>(image), tw, th);
    if (L.stops.size() < 2) continue;
    L.tiling = std::move(tiling);
    L.boxW = w;
    L.boxH = h;
    out.push_back(std::move(L));
  }
  return out;
}

void PaintBackgroundLayers(ImpellerDisplayListBuilder builder, const std::vector<BgLayer>& layers,
                           float x, float y, float opacity,
                           const std::function<void(ImpellerPaint)>& fillShape) {
  for (auto it = layers.rbegin(); it != layers.rend(); ++it) {
    std::vector<ImpellerColor> colors;
    for (const auto& c : it->colors) {
      colors.push_back({c[0], c[1], c[2], c[3] * opacity, kImpellerColorSpaceSRGB});
    }
    for (const auto& o : it->tiling.origins) {
      const float tx = x + o[0], ty = y + o[1];
      ImpellerColorSource src = nullptr;
      if (it->radial) {
        const ImpellerPoint origin = {0.0f, 0.0f};
        const ImpellerMatrix m = {{it->rx, 0, 0, 0, 0, it->ry, 0, 0, 0, 0, 1, 0,
                                   tx + it->center[0], ty + it->center[1], 0, 1}};
        src = ImpellerColorSourceCreateRadialGradientNew(
            &origin, 1.0f, (uint32_t)colors.size(), colors.data(), it->stops.data(),
            kImpellerTileModeClamp, &m);
      } else {
        const ImpellerPoint a = {tx + it->start[0], ty + it->start[1]};
        const ImpellerPoint b = {tx + it->end[0], ty + it->end[1]};
        src = ImpellerColorSourceCreateLinearGradientNew(
            &a, &b, (uint32_t)colors.size(), colors.data(), it->stops.data(),
            kImpellerTileModeClamp, nullptr);
      }
      if (src == nullptr) continue;
      // Its own paint: a colour source cannot be cleared once set, so a shared
      // paint would gradient-fill everything drawn after it.
      ImpellerPaint gp = ImpellerPaintNew();
      ImpellerPaintSetColorSource(gp, src);
      const bool clip = !it->tiling.single;
      if (clip) {
        // Clip to the tile (the box shape fill clips itself to the box).
        const ImpellerRect cell = {tx, ty, it->tiling.tw, it->tiling.th};
        ImpellerDisplayListBuilderSave(builder);
        ImpellerDisplayListBuilderClipRect(builder, &cell, kImpellerClipOperationIntersect);
      }
      fillShape(gp);
      if (clip) ImpellerDisplayListBuilderRestore(builder);
      ImpellerPaintRelease(gp);
      ImpellerColorSourceRelease(src);
    }
  }
}

}  // namespace rni
