// See TouchScroll.h.
#include "fabric/TouchScroll.h"

#include <algorithm>
#include <cmath>

namespace rni::touchscroll {

void VelocityTracker::Add(double tMs, float pos) {
  if (n_ == kCap) {
    std::copy(t_ + 1, t_ + kCap, t_);
    std::copy(p_ + 1, p_ + kCap, p_);
    --n_;
  }
  t_[n_] = tMs;
  p_[n_] = pos;
  ++n_;
}

float VelocityTracker::Velocity(double nowMs) const {
  int first = n_;
  while (first > 0 && nowMs - t_[first - 1] <= kVelocityWindowMs) --first;
  if (n_ - first < 2) return 0.0f;
  const double dt = t_[n_ - 1] - t_[first];
  if (dt <= 0.0) return 0.0f;
  return (float)((p_[n_ - 1] - p_[first]) / dt);
}

bool Flings(float v0, float decel) {
  return std::fabs(v0) >= kMinFlingVelocity && decel > 0.0f && decel < 1.0f;
}

// v(t) = v0 * d^t, so x(t) = from + v0 * (d^t - 1) / ln d.
float FlingOffsetAt(const Fling& f, double tMs) {
  const double ln = std::log((double)f.decel);
  return f.from + (float)(f.v0 * (std::pow((double)f.decel, tMs) - 1.0) / ln);
}

double FlingDurationMs(const Fling& f) {
  if (!Flings(f.v0, f.decel)) return 0.0;
  return std::log(kMinFlingVelocity / std::fabs(f.v0)) / std::log((double)f.decel);
}

float PageTarget(float offset, float velocity, float page, float dragStart,
                 float maxOffset) {
  if (page <= 0.0f) return std::clamp(offset, 0.0f, maxOffset);
  const float startPage = std::round(dragStart / page);
  float p;
  if (velocity >= kPageFlickVelocity) {
    p = std::floor(offset / page) + 1.0f;
  } else if (velocity <= -kPageFlickVelocity) {
    p = std::ceil(offset / page) - 1.0f;
  } else {
    p = std::round(offset / page);
  }
  p = std::clamp(p, startPage - 1.0f, startPage + 1.0f);
  return std::clamp(p * page, 0.0f, maxOffset);
}

float EaseOutCubic(float p) {
  const float q = 1.0f - std::clamp(p, 0.0f, 1.0f);
  return 1.0f - q * q * q;
}

}  // namespace rni::touchscroll
