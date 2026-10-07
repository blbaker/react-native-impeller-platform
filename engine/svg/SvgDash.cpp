#include "svg/SvgDash.h"

#include <algorithm>
#include <cmath>

#include "svg/SvgPath.h"

namespace rni {

namespace {

struct Pt {
  double x, y;
};
Pt lerp(Pt a, Pt b, double t) {
  return {a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t};
}

// kind 1 = line (p0 p1), 2 = quad (p0 p1 p2), 3 = cubic (p0 p1 p2 p3).
struct Seg {
  int kind;
  Pt p[4];
};

Pt evalSeg(const Seg& s, double t) {
  if (s.kind == 1) return lerp(s.p[0], s.p[1], t);
  Pt a = lerp(s.p[0], s.p[1], t), b = lerp(s.p[1], s.p[2], t);
  if (s.kind == 2) return lerp(a, b, t);
  Pt c = lerp(s.p[2], s.p[3], t);
  return lerp(lerp(a, b, t), lerp(b, c, t), t);
}

// de Casteljau split at t, keeping the [0,t] half (left) or the [t,1] half.
Seg splitSeg(const Seg& s, double t, bool left) {
  Seg r{s.kind, {}};
  if (s.kind == 1) {
    Pt m = lerp(s.p[0], s.p[1], t);
    r.p[0] = left ? s.p[0] : m;
    r.p[1] = left ? m : s.p[1];
  } else if (s.kind == 2) {
    Pt a = lerp(s.p[0], s.p[1], t), b = lerp(s.p[1], s.p[2], t);
    Pt m = lerp(a, b, t);
    if (left) {
      r.p[0] = s.p[0]; r.p[1] = a; r.p[2] = m;
    } else {
      r.p[0] = m; r.p[1] = b; r.p[2] = s.p[2];
    }
  } else {
    Pt a = lerp(s.p[0], s.p[1], t), b = lerp(s.p[1], s.p[2], t),
       c = lerp(s.p[2], s.p[3], t);
    Pt ab = lerp(a, b, t), bc = lerp(b, c, t), m = lerp(ab, bc, t);
    if (left) {
      r.p[0] = s.p[0]; r.p[1] = a; r.p[2] = ab; r.p[3] = m;
    } else {
      r.p[0] = m; r.p[1] = bc; r.p[2] = c; r.p[3] = s.p[3];
    }
  }
  return r;
}

// The exact same-kind piece of `s` between parameters t0 <= t1.
Seg subSeg(const Seg& s, double t0, double t1) {
  Seg l = t1 < 1.0 ? splitSeg(s, t1, true) : s;
  if (t0 <= 0.0 || t1 <= 0.0) return l;
  return splitSeg(l, std::min(1.0, t0 / t1), false);
}

Pt tangentAt(const Seg& s, double t) {
  Pt p = evalSeg(s, std::max(0.0, t - 1e-4)), q = evalSeg(s, std::min(1.0, t + 1e-4));
  double dx = q.x - p.x, dy = q.y - p.y, n = std::hypot(dx, dy);
  if (n < 1e-12) {  // degenerate at t: use the chord
    dx = s.p[s.kind].x - s.p[0].x;
    dy = s.p[s.kind].y - s.p[0].y;
    n = std::hypot(dx, dy);
    if (n < 1e-12) return {1.0, 0.0};
  }
  return {dx / n, dy / n};
}

// Arc length by a 48-chord table per curve (lines are exact). The table only
// maps a length to a parameter; the emitted geometry is the exact sub-curve.
constexpr int kSamples = 48;
struct Measured {
  Seg seg;
  double len = 0.0;
  std::vector<double> cum;  // cum[i] = length at t = i / kSamples
};

Measured measure(const Seg& s) {
  Measured m;
  m.seg = s;
  if (s.kind == 1) {
    m.len = std::hypot(s.p[1].x - s.p[0].x, s.p[1].y - s.p[0].y);
    return m;
  }
  m.cum.resize(kSamples + 1);
  m.cum[0] = 0.0;
  Pt prev = s.p[0];
  for (int i = 1; i <= kSamples; ++i) {
    Pt p = evalSeg(s, (double)i / kSamples);
    m.cum[i] = m.cum[i - 1] + std::hypot(p.x - prev.x, p.y - prev.y);
    prev = p;
  }
  m.len = m.cum[kSamples];
  return m;
}

double tAt(const Measured& m, double l) {
  if (m.len <= 0.0 || l <= 0.0) return 0.0;
  if (l >= m.len) return 1.0;
  if (m.seg.kind == 1) return l / m.len;
  auto it = std::lower_bound(m.cum.begin(), m.cum.end(), l);
  const int i = std::max(1, (int)(it - m.cum.begin()));
  const double a = m.cum[i - 1], b = m.cum[i];
  const double f = b > a ? (l - a) / (b - a) : 0.0;
  return ((i - 1) + f) / kSamples;
}

struct Subpath {
  std::vector<Seg> segs;
  bool closed = false;
};

// Records the parse as subpaths of absolute segments. A drawing command after
// Z with no M starts a new subpath at the closed one's start (SVG rule).
class Collector final : public SvgPathSink {
 public:
  std::vector<Subpath> subs;
  void moveTo(float x, float y) override {
    flush();
    cur_ = start_ = {x, y};
    open_ = true;
  }
  void lineTo(float x, float y) override {
    Pt e{x, y};
    add(Seg{1, {cur_, e}});
    cur_ = e;
  }
  void quadTo(float cx, float cy, float x, float y) override {
    Pt c{cx, cy}, e{x, y};
    add(Seg{2, {cur_, c, e}});
    cur_ = e;
  }
  void cubicTo(float c1x, float c1y, float c2x, float c2y, float x,
               float y) override {
    Pt c1{c1x, c1y}, c2{c2x, c2y}, e{x, y};
    add(Seg{3, {cur_, c1, c2, e}});
    cur_ = e;
  }
  void close() override {
    if (!open_) return;
    if (std::hypot(cur_.x - start_.x, cur_.y - start_.y) > 1e-9) {
      add(Seg{1, {cur_, start_}});  // the closing segment is dashed too
    }
    sub_.closed = true;
    flush();
    cur_ = start_;
  }
  void finish() { flush(); }

 private:
  void add(const Seg& s) {
    if (!open_) {
      start_ = cur_;
      open_ = true;
    }
    sub_.segs.push_back(s);
  }
  void flush() {
    if (!sub_.segs.empty()) subs.push_back(std::move(sub_));
    sub_ = Subpath{};
    open_ = false;
  }
  Pt cur_{0.0, 0.0}, start_{0.0, 0.0};
  bool open_ = false;
  Subpath sub_;
};

// Writes dashes onto the output builder. A dash is one open subpath: MoveTo
// at its start, then the pieces of every segment it covers, so a dash that
// runs through a corner gets the stroke's join there.
class Emitter {
 public:
  explicit Emitter(ImpellerPathBuilder b) : b_(b) {}
  bool down() const { return down_; }
  int dashes() const { return dashes_; }
  void piece(const Measured& m, double l0, double l1) {
    const Seg s = subSeg(m.seg, tAt(m, l0), tAt(m, l1));
    if (!down_) move(s.p[0]);
    if (s.kind == 1) {
      to(s.p[1]);
    } else if (s.kind == 2) {
      ImpellerPoint c = pt(s.p[1]), e = pt(s.p[2]);
      ImpellerPathBuilderQuadraticCurveTo(b_, &c, &e);
    } else {
      ImpellerPoint c1 = pt(s.p[1]), c2 = pt(s.p[2]), e = pt(s.p[3]);
      ImpellerPathBuilderCubicCurveTo(b_, &c1, &c2, &e);
    }
  }
  // A zero-length dash: a tiny segment along the tangent, so a round or
  // square cap paints its dot (and a square one is oriented with the path).
  void dot(const Measured& m, double l) {
    const double t = tAt(m, l);
    const Pt p = evalSeg(m.seg, t), d = tangentAt(m.seg, t);
    lift();
    move(p);
    to({p.x + d.x * 0.01, p.y + d.y * 0.01});
    lift();
  }
  void lift() { down_ = false; }
  void closeWhole() {
    ImpellerPathBuilderClose(b_);
    down_ = false;
  }

 private:
  static ImpellerPoint pt(Pt p) { return ImpellerPoint{(float)p.x, (float)p.y}; }
  void move(Pt p) {
    ImpellerPoint q = pt(p);
    ImpellerPathBuilderMoveTo(b_, &q);
    down_ = true;
    ++dashes_;
  }
  void to(Pt p) {
    ImpellerPoint q = pt(p);
    ImpellerPathBuilderLineTo(b_, &q);
  }
  ImpellerPathBuilder b_;
  bool down_ = false;
  int dashes_ = 0;
};

struct DashState {
  size_t idx;
  double remain;
  bool on() const { return (idx & 1u) == 0; }
};

// Where the pattern stands at distance 0 for this offset. Same boundary rule
// as Skia's find_first_interval: an offset that lands exactly on the end of a
// non-empty interval starts in the NEXT one.
DashState initialState(const std::vector<float>& pat, double sum,
                       double offset) {
  double off = std::fmod(offset, sum);
  if (off < 0.0) off += sum;
  size_t i = 0;
  for (size_t guard = 0; guard < 4 * pat.size() + 4; ++guard) {
    const double g = pat[i];
    if (off > g || (off == g && g != 0.0)) {
      off -= g;
      i = (i + 1) % pat.size();
    } else {
      return {i, g - off};
    }
  }
  return {0, pat[0]};
}

constexpr double kEps = 1e-9;

// Returns false when the dash budget ran out (caller strokes solid).
bool dashSubpath(const Subpath& sp, const std::vector<float>& pat, double sum,
                 double offset, bool capDots, Emitter& em, long& budget) {
  std::vector<Measured> ms;
  ms.reserve(sp.segs.size());
  double total = 0.0;
  for (const Seg& s : sp.segs) {
    ms.push_back(measure(s));
    total += ms.back().len;
  }
  if (total <= 0.0) return true;
  if (total / sum * (double)pat.size() > (double)budget) return false;

  DashState st = initialState(pat, sum, offset);
  // A closed subpath that starts inside an "on" interval: hold that first
  // dash back and draw it at the END, continuing the last dash when that one
  // is still on, so the start corner is joined (SkDashPath does the same).
  const bool joinFirst = sp.closed && st.on() && st.remain > kEps;
  const double firstLen = joinFirst ? st.remain : 0.0;
  // One dash covers the whole loop: that is the solid closed outline. The
  // 0.1% slack is for the "draw-on" idiom: an app sets [C, C] with C = 2*pi*r,
  // and the 4-cubic circle measures a hair longer than 2*pi*r, which would
  // otherwise leave a hairline butt-cap gap at the start point at offset 0.
  if (joinFirst && firstLen >= total - std::max(kEps, total * 1e-3)) {
    em.lift();
    for (const Measured& m : ms) em.piece(m, 0.0, m.len);
    em.closeWhole();
    return true;
  }
  bool inFirst = joinFirst;

  for (const Measured& m : ms) {
    double pos = 0.0;
    for (;;) {
      const double avail = m.len - pos;
      if (st.remain > avail + kEps) {
        // The interval runs past this segment: take the rest of it and keep
        // the pen down into the next segment.
        if (st.on() && !inFirst && avail > kEps) em.piece(m, pos, m.len);
        st.remain -= std::max(0.0, avail);
        break;
      }
      // The interval ends inside this segment.
      const double end = std::min(m.len, pos + st.remain);
      if (st.on() && !inFirst) {
        if (st.remain <= kEps) {
          if (capDots) em.dot(m, pos);
        } else if (end - pos > kEps) {
          em.piece(m, pos, end);
        }
        em.lift();
      }
      inFirst = false;
      pos = end;
      st.idx = (st.idx + 1) % pat.size();
      st.remain = pat[st.idx];
      if (--budget < 0) return false;
    }
  }

  if (joinFirst) {
    double need = firstLen;
    for (const Measured& m : ms) {
      if (need <= kEps) break;
      const double take = std::min(need, m.len);
      if (take > kEps) em.piece(m, 0.0, take);
      need -= take;
    }
  }
  em.lift();
  return true;
}

}  // namespace

std::vector<float> NormaliseSvgDashArray(const std::vector<float>& raw) {
  if (raw.empty()) return {};
  double sum = 0.0;
  for (float v : raw) {
    if (!std::isfinite(v) || v < 0.0f) return {};
    sum += v;
  }
  if (sum <= 0.0) return {};
  std::vector<float> out = raw;
  if (out.size() % 2 == 1) out.insert(out.end(), raw.begin(), raw.end());
  return out;
}

ImpellerPath BuildDashedSvgPath(const std::string& d,
                                const std::vector<float>& pattern,
                                float offset, bool capDots, int* dashesOut) {
  if (dashesOut != nullptr) *dashesOut = 0;
  if (pattern.empty() || pattern.size() % 2 != 0) return nullptr;
  double sum = 0.0;
  for (float v : pattern) sum += v;
  if (!(sum > 0.0)) return nullptr;

  Collector col;
  if (!ParseSvgPath(d, col)) return nullptr;
  col.finish();

  ImpellerPathBuilder pb = ImpellerPathBuilderNew();
  if (pb == nullptr) return nullptr;
  Emitter em(pb);
  long budget = 2L * kMaxSvgDashes;
  for (const Subpath& sp : col.subs) {
    if (!dashSubpath(sp, pattern, sum, offset, capDots, em, budget)) {
      ImpellerPathBuilderRelease(pb);
      return nullptr;
    }
  }
  if (em.dashes() > kMaxSvgDashes) {
    ImpellerPathBuilderRelease(pb);
    return nullptr;
  }
  ImpellerPath path = ImpellerPathBuilderTakePathNew(pb, kImpellerFillTypeNonZero);
  ImpellerPathBuilderRelease(pb);
  if (dashesOut != nullptr) *dashesOut = em.dashes();
  return path;
}

}  // namespace rni
