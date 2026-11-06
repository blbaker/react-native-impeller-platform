// Touch drag-to-scroll for <ScrollView>: the finger and momentum math.
//
// A touchscreen is the only input on a touchscreen kiosk, and RN's ScrollView
// leaves dragging to the platform: iOS's UIScrollView and Android's
// ReactScrollView track the finger natively and REPORT onScrollBeginDrag,
// onScroll, onScrollEndDrag and the momentum pair to JS. Impeller has no
// native scroll view, so the host does that tracking. This file holds only
// the arithmetic (no SceneGraph, no React); FabricHostTouchScroll.cpp is the
// glue that moves offsets and emits the events.
#pragma once

namespace rni::touchscroll {

// Movement up to this many points is a tap, not a drag. iOS pans begin at
// about 10 pt; Android's touch slop is 8 dp.
constexpr float kSlopPt = 10.0f;
// Release velocity is measured over this window. A finger that stopped for
// longer than this lifts with zero velocity, so nothing flings.
constexpr double kVelocityWindowMs = 100.0;
// Slower releases (points per ms) do not fling. A fling ends below it too.
constexpr float kMinFlingVelocity = 0.05f;
// A paged release this fast goes to the next page whatever the distance.
constexpr float kPageFlickVelocity = 0.3f;
// A page settle eases out over this long.
constexpr double kPageSettleMs = 300.0;

// Finger positions along one axis with their times, newest last.
class VelocityTracker {
 public:
  void Reset() { n_ = 0; }
  void Add(double tMs, float pos);
  // Points per ms over the samples inside kVelocityWindowMs before nowMs;
  // 0 with fewer than two of them.
  float Velocity(double nowMs) const;

 private:
  static constexpr int kCap = 16;
  double t_[kCap]{};
  float p_[kCap]{};
  int n_ = 0;
};

// A release with velocity v0 (points per ms) that decays by `decel` per ms,
// RN's decelerationRate (0.998 normal, 0.99 fast).
struct Fling {
  float from = 0.0f;
  float v0 = 0.0f;
  float decel = 0.998f;
};
// Whether this release flings at all (speed and a usable decelerationRate).
bool Flings(float v0, float decel);
float FlingOffsetAt(const Fling& f, double tMs);
// Time until the speed falls below kMinFlingVelocity.
double FlingDurationMs(const Fling& f);

// The page offset a paged release settles on: velocity first (a flick turns
// one page), else the nearest page, never more than one page from where the
// drag started, clamped to [0, maxOffset].
float PageTarget(float offset, float velocity, float page, float dragStart,
                 float maxOffset);

float EaseOutCubic(float p);

// One finger on a ScrollView, from touch down to lift.
struct Gesture {
  bool armed = false;    // a finger is down
  bool claimed = false;  // a ScrollView owns this drag
  bool blocked = false;  // a JS responder kept it; stays JS's until lift
  float downX = 0.0f, downY = 0.0f;
  int tag = 0;
  bool horizontal = false;
  float startOffset = 0.0f;  // on the drag axis
  float otherAxis = 0.0f;    // the offset on the other axis, left alone
  float slack = 0.0f;        // the slop taken up before the content moved
  float offset = 0.0f;       // current (clamped) offset on the drag axis
  bool paging = false;
  float decel = 0.998f;
  float page = 0.0f;
  float maxOffset = 0.0f;
  VelocityTracker velocity;
};

// What runs after the finger lifts: a fling or a page settle.
struct Momentum {
  bool active = false;
  int tag = 0;
  bool horizontal = false;
  bool paging = false;
  double t0Ms = 0.0, durationMs = 0.0;
  float from = 0.0f, to = 0.0f, otherAxis = 0.0f;
  Fling fling;
};

struct State {
  Gesture gesture;
  Momentum momentum;
};

}  // namespace rni::touchscroll
