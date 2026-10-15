// FP-18: see DamageTracker.h (model: flow/diff_context.cc,
// flow/compositor_context.cc ShouldPerformPartialRepaint).
#include "scenegraph/DamageTracker.h"

#include <algorithm>
#include <cmath>
#include <utility>

namespace rni {

namespace {
// Device pixels added around every box: AA fringe of an edge that lands
// between pixels.
constexpr float kAaFringePx = 2.0f;
}  // namespace

bool ShouldPerformPartialRepaint(float damageW, float damageH, int surfaceW, int surfaceH) {
  if (surfaceW <= 0 || surfaceH <= 0) return false;
  if (damageW >= (float)surfaceW && damageH >= (float)surfaceH) return false;
  const float rx = damageW / (float)surfaceW;
  const float ry = damageH / (float)surfaceH;
  return rx <= kImpellerRepaintRatio || ry <= kImpellerRepaintRatio;
}

void DamageTracker::Box::Add(const Box& o) {
  if (o.empty) return;
  if (empty) {
    *this = o;
    return;
  }
  l = std::min(l, o.l);
  t = std::min(t, o.t);
  r = std::max(r, o.r);
  b = std::max(b, o.b);
}

void DamageTracker::Box::Intersect(const Box& clip) {
  if (empty) return;
  if (clip.empty) {
    empty = true;
    return;
  }
  l = std::max(l, clip.l);
  t = std::max(t, clip.t);
  r = std::min(r, clip.r);
  b = std::min(b, clip.b);
  if (r <= l || b <= t) empty = true;
}

bool DamageTracker::MayPaintInside(int tag, const Box& clip) const {
  auto it = prev_.find(tag);  // EndWalk swapped the finished walk into prev_
  if (it == prev_.end() || it->second.subUnbounded) return true;
  Box b = it->second.sub;
  b.Intersect(clip);
  return !b.empty;
}

void DamageTracker::BeginWalk() {
  cur_.clear();
  order_.clear();
  walkFull_ = nullptr;
}

void DamageTracker::Record(ImpellerDisplayListBuilder builder, int tag, int parent,
                           ImpellerRect local, float outset, bool unbounded,
                           bool clipsChildren, bool volatileNow) {
  Box box;
  if (!unbounded) {
    ImpellerMatrix m{};
    ImpellerDisplayListBuilderGetTransform(builder, &m);
    // Column-major: x' = m0 x + m4 y + m12, w' = m3 x + m7 y + m15.
    if (m.m[3] != 0.0f || m.m[7] != 0.0f || m.m[15] != 1.0f) {
      unbounded = true;  // perspective: the box is not an affine image
    } else {
      const float x0 = local.x - outset, y0 = local.y - outset;
      const float x1 = local.x + local.width + outset, y1 = local.y + local.height + outset;
      const float xs[4] = {x0, x1, x0, x1}, ys[4] = {y0, y0, y1, y1};
      for (int i = 0; i < 4; ++i) {
        const float dx = m.m[0] * xs[i] + m.m[4] * ys[i] + m.m[12];
        const float dy = m.m[1] * xs[i] + m.m[5] * ys[i] + m.m[13];
        Box p;
        p.l = p.r = dx;
        p.t = p.b = dy;
        p.empty = false;
        box.Add(p);
      }
      box.l -= kAaFringePx;
      box.t -= kAaFringePx;
      box.r += kAaFringePx;
      box.b += kAaFringePx;
      if (!std::isfinite(box.l) || !std::isfinite(box.t) || !std::isfinite(box.r) ||
          !std::isfinite(box.b)) {
        unbounded = true;
      }
    }
  }
  auto [it, inserted] = cur_.try_emplace(tag);
  Rec& rec = it->second;
  if (inserted) {
    order_.push_back(tag);
    rec.parent = parent;
  }
  rec.own.Add(box);
  rec.unbounded = rec.unbounded || unbounded;
  rec.clips = rec.clips || clipsChildren;
  rec.isVolatile = rec.isVolatile || volatileNow;
}

void DamageTracker::Finish(FrameDamage* out, const std::vector<int>& unknown) {
  const int W = out->surfaceW, H = out->surfaceH;
  // Children were first visited after their parents: fold in reverse.
  for (auto& [tag, rec] : cur_) {
    rec.sub = rec.own;
    rec.subUnbounded = rec.unbounded;
  }
  for (auto i = order_.rbegin(); i != order_.rend(); ++i) {
    const Rec& rec = cur_[*i];
    auto p = cur_.find(rec.parent);
    if (p == cur_.end() || p->first == *i) continue;
    Box contrib = rec.sub;
    bool unb = rec.subUnbounded;
    if (p->second.clips && !p->second.unbounded) {
      contrib = unb ? p->second.own : contrib;
      contrib.Intersect(p->second.own);
      unb = false;
    }
    p->second.sub.Add(contrib);
    p->second.subUnbounded = p->second.subUnbounded || unb;
  }

  const char* full = nullptr;
  if (full_.exchange(false, std::memory_order_acq_rel)) {
    full = fullReason_.load(std::memory_order_relaxed);
  }
  if (!full && walkFull_) full = walkFull_;
  if (!full && (W <= 0 || H <= 0)) full = "no_surface";
  if (!full && (W != prevW_ || H != prevH_ || out->scale != prevScale_)) full = "resize";
  if (!full && !unknown.empty()) full = "unpainted_tag";

  Box d;
  auto addTag = [&](const Rec* a, const Rec* b) {
    for (const Rec* r : {a, b}) {
      if (!r) continue;
      if (r->subUnbounded) {
        if (!full) full = "unbounded";
        return;
      }
      d.Add(r->sub);
    }
  };
  auto find = [](const Map& m, int tag) -> const Rec* {
    auto it = m.find(tag);
    return it == m.end() ? nullptr : &it->second;
  };
  if (!full) {
    for (int tag : marked_) addTag(find(cur_, tag), find(prev_, tag));
    for (const auto& [tag, rec] : cur_) {
      if (rec.isVolatile) addTag(&rec, find(prev_, tag));
    }
    for (const auto& [tag, rec] : prev_) {
      if (rec.isVolatile) addTag(&rec, find(cur_, tag));
    }
  }

  out->baseSeq = seq_;
  out->seq = ++seq_;
  out->partial = false;
  out->x = out->y = 0;
  out->w = W;
  out->h = H;
  out->reason = full ? full : "";
  if (!full) {
    Box surface;
    surface.l = surface.t = 0;
    surface.r = (float)W;
    surface.b = (float)H;
    surface.empty = false;
    d.Intersect(surface);
    if (d.empty) {
      out->partial = true;
      out->w = out->h = 0;
      out->reason = "no_change";
    } else {
      const int x0 = (int)std::floor(d.l), y0 = (int)std::floor(d.t);
      const int x1 = (int)std::ceil(d.r), y1 = (int)std::ceil(d.b);
      if (ShouldPerformPartialRepaint((float)(x1 - x0), (float)(y1 - y0), W, H)) {
        out->partial = true;
        out->x = x0;
        out->y = y0;
        out->w = x1 - x0;
        out->h = y1 - y0;
        out->reason = "damage";
      } else {
        out->reason = "ratio";
      }
    }
  }
  std::swap(cur_, prev_);
  cur_.clear();
  marked_.clear();
  prevW_ = W;
  prevH_ = H;
  prevScale_ = out->scale;
}

}  // namespace rni
