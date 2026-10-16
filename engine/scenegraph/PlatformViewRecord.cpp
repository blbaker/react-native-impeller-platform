// FP-44: RECORD side of platform views. Model: flow/layers/platform_view_layer.cc
// (Preroll: the view's EmbeddedViewParams from the state stack's matrix and
// mutators; Paint: CompositeEmbeddedView switches to the view's slice) and
// flow/view_slicer.cc SliceViews (each slice's drawn rects that intersect this
// or an earlier view become that view's overlay layer, rendered with the slice
// clipped to the overlay rect over transparent).
//
// Our walk paints straight into one builder, so the slices are recorded by a
// second walk per overlay: the same tree, where a node's own pixels go to a sink
// builder unless the node is painted after view i and before view i+1 (its
// transforms, opacity layers and clips still apply, so the slice composes the
// same way it does in the full frame).
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "scenegraph/SceneGraph.h"

namespace rni {

namespace {

// The box (x,y,w,h) through the builder's current matrix, divided by `div`.
// *translateOnly: the matrix is the walk's root scale plus a translation.
PvRect DeviceBox(ImpellerDisplayListBuilder b, float x, float y, float w, float h,
                 float rootScale, float div, bool* translateOnly) {
  ImpellerMatrix m{};
  ImpellerDisplayListBuilderGetTransform(b, &m);
  if (translateOnly != nullptr) {
    auto same = [](float a, float c) { return std::fabs(a - c) < 1e-4f; };
    *translateOnly = same(m.m[0], rootScale) && same(m.m[5], rootScale) && same(m.m[1], 0) &&
                     same(m.m[4], 0) && same(m.m[3], 0) && same(m.m[7], 0) && same(m.m[15], 1);
  }
  const float xs[4] = {x, x + w, x, x + w}, ys[4] = {y, y, y + h, y + h};
  PvRect r{1e30f, 1e30f, -1e30f, -1e30f};
  for (int i = 0; i < 4; ++i) {
    const float wv = m.m[3] * xs[i] + m.m[7] * ys[i] + m.m[15];
    const float s = wv != 0.0f ? 1.0f / wv : 1.0f;
    const float dx = (m.m[0] * xs[i] + m.m[4] * ys[i] + m.m[12]) * s / div;
    const float dy = (m.m[1] * xs[i] + m.m[5] * ys[i] + m.m[13]) * s / div;
    r.l = std::min(r.l, dx);
    r.t = std::min(r.t, dy);
    r.r = std::max(r.r, dx);
    r.b = std::max(r.b, dy);
  }
  return r;
}

PvRect RoundOut(const PvRect& r) {
  return PvRect{std::floor(r.l), std::floor(r.t), std::ceil(r.r), std::ceil(r.b)};
}

PvRect RoundIn(const PvRect& r) {
  return PvRect{std::ceil(r.l), std::ceil(r.t), std::floor(r.r), std::floor(r.b)};
}

// Does the node paint pixels of its own (DisplayListBuilder drawn rects)?
bool DrawsOwnPixels(const SceneNode& n) {
  if (n.bg[3] > 0.0f || !n.shadows.empty() || n.elevation > 0.0f) return true;
  for (float bw : n.borderWidths) {
    if (bw > 0.0f) return true;
  }
  return n.isParagraph || n.isTextInput || n.isImage || n.isSwitch || n.isSpinner ||
         n.isSvgPath || n.isSvgRoot || n.isExternalTexture || n.isWorldRaster;
}

uint8_t Byte(float v) { return (uint8_t)std::lround(std::clamp(v, 0.0f, 1.0f) * 255.0f); }

}  // namespace

std::shared_ptr<PlatformViewFrame> SceneGraph::takePlatformViewFrame() {
  std::lock_guard<std::mutex> lock(mutex_);
  return std::exchange(pvFrame_, nullptr);
}

void SceneGraph::pvBeginWalkLocked() {
  if (!pvMainWalk()) return;
  pvClips_.clear();
  pvFrame_ = nullptr;
}

void SceneGraph::pvPushClipLocked(ImpellerDisplayListBuilder b, float x, float y, float w,
                                  float h) {
  const PvRect r = DeviceBox(b, x, y, w, h, pointScale_ * pvWalkScale_, pvWalkScale_, nullptr);
  DamageTracker::Box box{r.l, r.t, r.r, r.b, r.Empty()};
  if (!pvClips_.empty()) box.Intersect(pvClips_.back());
  pvClips_.push_back(box);
}

void SceneGraph::pvPopClipLocked() {
  if (!pvClips_.empty()) pvClips_.pop_back();
}

void SceneGraph::pvNoteViewLocked(ImpellerDisplayListBuilder b, const SceneNode& node, float x,
                                  float y, float w, float h, float alpha) {
  if (pvSliceWalk_) {  // view_slicer: the slice after view i ends at view i+1
    if (node.tag == pvSliceStart_) pvSliceActive_ = true;
    if (node.tag == pvSliceEnd_) pvSliceActive_ = false;
    return;
  }
  if (!pvEmbedded_) {  // no embedder on this host: the view's colour, in place
    ImpellerPaint p = ImpellerPaintNew();
    const ImpellerColor c = {node.pvColor[0], node.pvColor[1], node.pvColor[2],
                             node.pvColor[3] * alpha, kImpellerColorSpaceSRGB};
    ImpellerPaintSetColor(p, &c);
    const ImpellerRect r = {x, y, w, h};
    ImpellerDisplayListBuilderDrawRect(b, &r, p);
    ImpellerPaintRelease(p);
    return;
  }
  if (!pvMainWalk()) return;  // a hole; only the frame's own walk embeds
  PlatformViewParams v;
  v.tag = node.tag;
  v.box = DeviceBox(b, x, y, w, h, pointScale_ * pvWalkScale_, pvWalkScale_, &v.translateOnly);
  if (!pvClips_.empty()) {
    const auto& c = pvClips_.back();
    v.clipped = true;
    v.clip = c.empty ? PvRect{} : PvRect{c.l, c.t, c.r, c.b};
  }
  v.r = Byte(node.pvColor[0]);
  v.g = Byte(node.pvColor[1]);
  v.b = Byte(node.pvColor[2]);
  auto once = [&](std::vector<facebook::react::Tag>& seen) {
    if (std::find(seen.begin(), seen.end(), node.tag) != seen.end()) return false;
    seen.push_back(node.tag);
    return true;
  };
  if (once(pvSeen_)) {
    std::printf("rn-impeller: platform_view tag=%d box=%.0f,%.0f,%.0f,%.0f rgb=%d,%d,%d\n",
                node.tag, v.box.l, v.box.t, v.box.r, v.box.b, v.r, v.g, v.b);
  }
  if (!v.translateOnly && once(pvUnsupportedLogged_)) {
    std::printf("rn-impeller: platform_view_unsupported tag=%d mutator=transform "
                "(only translate composites; placed at the transformed bounds)\n",
                node.tag);
  }
  std::fflush(stdout);
  if (!pvFrame_) pvFrame_ = std::make_shared<PlatformViewFrame>();
  pvFrame_->views.push_back(v);
}

void SceneGraph::pvNoteDrawLocked(ImpellerDisplayListBuilder b, const SceneNode& node, float x,
                                  float y, float w, float h) {
  if (node.isPlatformView || !DrawsOwnPixels(node) || pvFrame_->views.empty()) return;
  PvRect box = DeviceBox(b, x, y, w, h, 1.0f, pvWalkScale_, nullptr);
  if (!pvClips_.empty()) {
    const auto& c = pvClips_.back();
    box = c.empty ? PvRect{} : box.Intersect(PvRect{c.l, c.t, c.r, c.b});
  }
  if (box.Empty()) return;
  PvRect joined;
  for (const auto& v : pvFrame_->views) {
    const PvRect vis = v.Visible();
    // SliceViews: a rect that only touches the rounded-out edge is ignored.
    if (box.Intersect(RoundIn(vis)).Empty()) continue;
    joined = joined.Union(RoundOut(box.Intersect(RoundOut(vis))));
  }
  auto& slice = pvFrame_->views.back();
  slice.overlay = slice.overlay.Union(joined);
}

void SceneGraph::pvRecordOverlaysLocked(float pointScale) {
  if (!pvFrame_ || !pvEmbedded_) return;
  const int savedPainted = painted_, savedSprites = spritesDrawn_;
  const bool savedSpinning = spinnerAnimating_.load(std::memory_order_relaxed);
  const std::string savedNote = extTextureNote_;
  auto& views = pvFrame_->views;
  pvSink_ = ImpellerDisplayListBuilderNew(nullptr);
  for (size_t i = 0; i < views.size(); ++i) {
    PlatformViewParams& v = views[i];
    if (v.overlay.Empty()) continue;
    const PvRect o = RoundOut(v.overlay);
    v.overlay = o;
    ImpellerDisplayListBuilder ob = ImpellerDisplayListBuilderNew(nullptr);
    ImpellerDisplayListBuilderTranslate(ob, -o.l, -o.t);
    const ImpellerRect cr = {o.l, o.t, o.r - o.l, o.b - o.t};
    ImpellerDisplayListBuilderClipRect(ob, &cr, kImpellerClipOperationIntersect);
    ImpellerDisplayListBuilderScale(ob, pointScale, pointScale);
    pvSliceStart_ = v.tag;
    pvSliceEnd_ = i + 1 < views.size() ? views[i + 1].tag : 0;
    pvSliceActive_ = false;
    pvSliceWalk_ = true;
    rebuildPaintRegistriesLocked();
    svgUseDepth_ = 0;
    for (auto rootTag : roots_) {
      auto it = nodes_.find(rootTag);
      if (it != nodes_.end()) paintNode(ob, it->second, 0, 0);
    }
    paintModalsLocked(ob);
    pvSliceWalk_ = false;
    v.overlayList = ImpellerDisplayListBuilderCreateDisplayListNew(ob);
    ImpellerDisplayListBuilderRelease(ob);
  }
  ImpellerDisplayListBuilderRelease(pvSink_);
  pvSink_ = nullptr;
  painted_ = savedPainted;
  spritesDrawn_ = savedSprites;
  spinnerAnimating_.store(savedSpinning, std::memory_order_relaxed);
  extTextureNote_ = savedNote;
}

}  // namespace rni
