// Touch drag-to-scroll: FabricHost glue. The math is in TouchScroll.h; this
// file resolves the ScrollView, moves its offset and tells JS, in the order
// iOS's UIScrollView does: onScrollBeginDrag, onScroll per move,
// onScrollEndDrag, then onMomentumScrollBegin, onScroll per frame and
// onMomentumScrollEnd for a fling or a page settle.
//
// Event-thread only: the touch calls come from the GLFW/wl_touch callbacks
// and tickTouchScroll from the frame loop, all on the main thread.
#include "fabric/FabricHost.h"

#include <react/renderer/components/scrollview/ScrollViewEventEmitter.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>

#include "scenegraph/SceneGraph.h"

namespace rni {

namespace react = facebook::react;
namespace ts = touchscroll;

namespace {

enum class Phase { BeginDrag, EndDrag, MomentumBegin, MomentumEnd };

double NowMs() {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// Same payload emitScroll builds for onScroll, for the four phase events.
void EmitPhase(SceneGraph* sg, int tag, Phase phase, const SceneGraph::ScrollResult& r,
               bool horizontal, float velocity = 0.0f, float target = 0.0f) {
  auto em = std::dynamic_pointer_cast<const react::ScrollViewEventEmitter>(
      sg->eventEmitterFor((react::Tag)tag));
  if (!em) return;
  react::ScrollEvent e{};
  e.contentOffset = {(react::Float)r.offsetX, (react::Float)r.offsetY};
  e.contentSize = {(react::Float)r.contentWidth, (react::Float)r.contentHeight};
  e.containerSize = {(react::Float)r.containerWidth, (react::Float)r.containerHeight};
  e.zoomScale = 1.0f;
  e.timestamp = (react::Float)(NowMs() / 1000.0);
  switch (phase) {
    case Phase::BeginDrag:
      em->onScrollBeginDrag(e);
      break;
    case Phase::EndDrag: {
      react::ScrollEndDragEvent end(e);
      end.velocity = {(react::Float)(horizontal ? velocity : 0.0f),
                      (react::Float)(horizontal ? 0.0f : velocity)};
      end.targetContentOffset = {(react::Float)(horizontal ? target : r.offsetX),
                                 (react::Float)(horizontal ? r.offsetY : target)};
      em->onScrollEndDrag(end);
      break;
    }
    case Phase::MomentumBegin:
      em->onMomentumScrollBegin(e);
      break;
    case Phase::MomentumEnd:
      em->onMomentumScrollEnd(e);
      break;
  }
}

// Moves `tag` to `axisOffset` on its drag axis; scrollTo clamps it.
SceneGraph::ScrollResult MoveAxis(SceneGraph* sg, int tag, bool horizontal,
                                  float axisOffset, float otherAxis) {
  return sg->scrollTo((react::Tag)tag, horizontal ? axisOffset : otherAxis,
                      horizontal ? otherAxis : axisOffset, false);
}

}  // namespace

// The ScrollView took the gesture: end JS's touch with a cancel (no onPress),
// and route nothing more to the pressed control.
void FabricHost::cancelTouchCapture(float x, float y) {
  if (capturedTag_ == 0) return;
  dispatchTouchToTarget(TouchPhase::Cancel, (react::Tag)capturedTag_, x, y);
  capturedTag_ = 0;
}

void FabricHost::stopTouchScrollMomentum(const char* why) {
  ts::Momentum& m = touchScroll_.momentum;
  if (!m.active) return;
  m.active = false;
  const auto r = sceneGraph_->scrollStateOf((react::Tag)m.tag);
  std::printf("rn-impeller: touch_scroll momentum_end tag=%d offset=%.1f reason=%s\n",
              m.tag, m.horizontal ? r.offsetX : r.offsetY, why);
  std::fflush(stdout);
  if (r.tag != 0) EmitPhase(sceneGraph_, m.tag, Phase::MomentumEnd, r, m.horizontal);
}

void FabricHost::touchScrollDown(float x, float y) {
  if (!sceneGraph_) return;
  // A finger on a list that is still moving stops it, as on iOS and Android.
  // Reporting the end first also lets ScrollView.js see it as just-stopped
  // (its 16 ms window), so this tap goes to the list, not the row under it.
  const ts::Momentum& m = touchScroll_.momentum;
  if (m.active && sceneGraph_->hitIsInside((react::Tag)m.tag, x, y)) {
    stopTouchScrollMomentum("touch");
  }
  touchScroll_.gesture = ts::Gesture{};
  touchScroll_.gesture.armed = true;
  touchScroll_.gesture.downX = x;
  touchScroll_.gesture.downY = y;
}

void FabricHost::applyTouchDrag(float x, float y, double nowMs) {
  ts::Gesture& g = touchScroll_.gesture;
  const float finger = g.horizontal ? x - g.downX : y - g.downY;
  g.velocity.Add(nowMs, finger);
  const auto r = MoveAxis(sceneGraph_, g.tag, g.horizontal,
                          g.startOffset - (finger - g.slack), g.otherAxis);
  if (r.tag == 0) return;
  g.offset = g.horizontal ? r.offsetX : r.offsetY;
  if (r.moved) {
    emitScroll(g.tag, r.offsetX, r.offsetY, r.contentWidth, r.contentHeight,
               r.containerWidth, r.containerHeight);
  }
}

bool FabricHost::touchScrollMove(float x, float y) {
  ts::Gesture& g = touchScroll_.gesture;
  if (!g.armed || !sceneGraph_) return false;
  const double now = NowMs();
  if (g.claimed) {
    applyTouchDrag(x, y, now);
    return true;
  }
  if (g.blocked) return false;
  const float dx = x - g.downX, dy = y - g.downY;
  if (std::fabs(dx) <= ts::kSlopPt && std::fabs(dy) <= ts::kSlopPt) return false;
  // PanResponder (anything whose responder grant returns true) asks RN to
  // block native gestures; Android's ScrollView honours that and so does
  // this. Pressability does not ask, so rows inside a list still scroll.
  if (jsResponderBlocksNative_.load(std::memory_order_acquire)) {
    g.blocked = true;
    std::printf("rn-impeller: touch_scroll blocked js_responder=%d\n",
                jsResponderTag_.load(std::memory_order_acquire));
    std::fflush(stdout);
    return false;
  }
  bool horizontal = std::fabs(dx) > std::fabs(dy);
  auto t = sceneGraph_->touchScrollTargetAt(g.downX, g.downY, horizontal);
  if (t.state.tag == 0 && std::fabs(horizontal ? dy : dx) > ts::kSlopPt) {
    horizontal = !horizontal;
    t = sceneGraph_->touchScrollTargetAt(g.downX, g.downY, horizontal);
  }
  if (t.state.tag == 0) return false;  // nothing scrolls this way; JS keeps it

  const auto& s = t.state;
  g.claimed = true;
  g.tag = (int)s.tag;
  g.horizontal = horizontal;
  g.startOffset = horizontal ? s.offsetX : s.offsetY;
  g.otherAxis = horizontal ? s.offsetY : s.offsetX;
  g.offset = g.startOffset;
  // The content starts moving at the slop, not jumping by it.
  g.slack = (horizontal ? dx : dy) > 0.0f ? ts::kSlopPt : -ts::kSlopPt;
  g.paging = t.paging;
  g.decel = t.decelerationRate;
  g.page = horizontal ? s.containerWidth : s.containerHeight;
  g.maxOffset = std::max(0.0f, horizontal ? s.contentWidth - s.containerWidth
                                          : s.contentHeight - s.containerHeight);
  g.velocity.Reset();
  std::printf("rn-impeller: touch_scroll claim tag=%d axis=%c at=%.1f,%.1f offset=%.1f paging=%d\n",
              g.tag, horizontal ? 'x' : 'y', x, y, g.startOffset, g.paging ? 1 : 0);
  std::fflush(stdout);
  // RN Android does the same when its ScrollView intercepts a drag.
  cancelTouchCapture(x, y);
  endTextSelectionDrag();
  EmitPhase(sceneGraph_, g.tag, Phase::BeginDrag, s, horizontal);
  applyTouchDrag(x, y, now);
  return true;
}

bool FabricHost::touchScrollUp(float x, float y, bool cancelled) {
  if (!sceneGraph_ || !touchScroll_.gesture.claimed) {
    touchScroll_.gesture = ts::Gesture{};
    return false;
  }
  const double now = NowMs();
  // A cancel arrives at a far-away point; only a real lift is a position.
  if (!cancelled) applyTouchDrag(x, y, now);
  const ts::Gesture g = touchScroll_.gesture;
  touchScroll_.gesture = ts::Gesture{};
  // The finger moving down/right moves the content toward offset 0.
  const float v = cancelled ? 0.0f : -g.velocity.Velocity(now);

  ts::Momentum m{};
  m.tag = g.tag;
  m.horizontal = g.horizontal;
  m.otherAxis = g.otherAxis;
  m.from = g.offset;
  m.t0Ms = now;
  float target = g.offset;
  if (g.paging && g.page > 0.0f) {
    target = ts::PageTarget(g.offset, v, g.page, g.startOffset, g.maxOffset);
    m.paging = true;
    m.durationMs = ts::kPageSettleMs;
  } else if (ts::Flings(v, g.decel)) {
    m.fling = ts::Fling{g.offset, v, g.decel};
    m.durationMs = ts::FlingDurationMs(m.fling);
    target = std::clamp(ts::FlingOffsetAt(m.fling, m.durationMs), 0.0f, g.maxOffset);
  }
  m.to = target;
  m.active = target != g.offset;
  std::printf("rn-impeller: touch_scroll end_drag tag=%d offset=%.1f velocity=%.3f target=%.1f momentum=%d cancelled=%d\n",
              g.tag, g.offset, v, target, m.active ? 1 : 0, cancelled ? 1 : 0);
  std::fflush(stdout);
  const auto r = sceneGraph_->scrollStateOf((react::Tag)g.tag);
  if (r.tag == 0) return true;
  EmitPhase(sceneGraph_, g.tag, Phase::EndDrag, r, g.horizontal, v, target);
  if (m.active) {
    stopTouchScrollMomentum("replaced");
    touchScroll_.momentum = m;
    EmitPhase(sceneGraph_, g.tag, Phase::MomentumBegin, r, g.horizontal);
  }
  return true;
}

bool FabricHost::tickTouchScroll() {
  ts::Momentum& m = touchScroll_.momentum;
  if (!m.active || !sceneGraph_) return false;
  const double t = NowMs() - m.t0Ms;
  bool done = t >= m.durationMs;
  float want;
  if (m.paging) {
    want = done ? m.to
                : m.from + (m.to - m.from) * ts::EaseOutCubic((float)(t / m.durationMs));
  } else {
    want = ts::FlingOffsetAt(m.fling, std::min(t, m.durationMs));
  }
  const auto r = MoveAxis(sceneGraph_, m.tag, m.horizontal, want, m.otherAxis);
  if (r.tag == 0) {  // unmounted mid-flight: nothing left to report to
    m.active = false;
    return false;
  }
  const float got = m.horizontal ? r.offsetX : r.offsetY;
  if (!m.paging && got != want) done = true;  // the fling hit an end
  if (r.moved) {
    emitScroll(m.tag, r.offsetX, r.offsetY, r.contentWidth, r.contentHeight,
               r.containerWidth, r.containerHeight);
  }
  if (done) stopTouchScrollMomentum(m.paging ? "settled" : "decayed");
  return r.moved;
}

bool FabricHost::touchScrollAnimating() const { return touchScroll_.momentum.active; }

void FabricHost::stopTouchScrollFor(int tag) {
  if (touchScroll_.momentum.active && touchScroll_.momentum.tag == tag) {
    stopTouchScrollMomentum("command");
  }
}

void FabricHost::setJsResponder(int tag, bool isResponder, bool blockNative) {
  jsResponderTag_.store(isResponder ? tag : 0, std::memory_order_release);
  jsResponderBlocksNative_.store(isResponder && blockNative, std::memory_order_release);
}

}  // namespace rni
