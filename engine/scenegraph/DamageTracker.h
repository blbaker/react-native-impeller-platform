// FP-18: frame damage between the last two recorded frames, and Flutter's
// 0.7 partial-repaint rule.
//
// Model: flutter/flow/diff_context.cc + flow/frame_damage.cc (the damage of a
// frame is the old and new paint bounds of every layer that changed between
// the previous layer tree and this one) and
// flow/compositor_context.cc CompositorContext::ShouldPerformPartialRepaint
// (kImpellerRepaintRatio = 0.7: clip to the damage only when it covers at most
// 70% of the surface width OR height, else repaint everything).
//
// Our retained tree has no layer identity to diff, so the CHANGE set comes from
// the scene's own mutation paths (applyMutations / updateViewProps mark the
// tags they touch) and the BOUNDS come from the paint walk: each visited node
// records its device-space box (frame + outsets through the builder's current
// transform) and the walk folds children into their parents' subtree boxes.
// Damage = for every changed tag, its subtree box last frame U this frame.
// Anything we cannot bound (shadows, blur/drop-shadow ancestors, SVG content,
// images, perspective, a change with no tag) makes the frame a full repaint.
//
// Thread model: every method except MarkFull runs under SceneGraph::mutex_.
// MarkFull is an atomic store (untagged bumpVersion() from any thread).
#pragma once

#include <atomic>
#include <cstdint>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "impeller.h"

namespace rni {

// What RECORD hands RASTER. Device pixels, top-left origin.
struct FrameDamage {
  int surfaceW = 0, surfaceH = 0;  // in: the surface the frame is recorded for
  float scale = 1.0f;              // in: the point -> pixel scale it is recorded at
  uint64_t seq = 0;      // this walk
  uint64_t baseSeq = 0;  // the walk whose pixels a partial frame builds on
  bool partial = false;  // clip to rect; pixels outside come from baseSeq
  int x = 0, y = 0, w = 0, h = 0;  // the clip (w*h may be 0: nothing changed)
  const char* reason = "";
  long long pixels() const { return partial ? (long long)w * h : (long long)surfaceW * surfaceH; }
};

// flow/compositor_context.cc:200 (kImpellerRepaintRatio).
constexpr float kImpellerRepaintRatio = 0.7f;
// CompositorContext::ShouldPerformPartialRepaint, same comparisons.
bool ShouldPerformPartialRepaint(float damageW, float damageH, int surfaceW, int surfaceH);

class DamageTracker {
 public:
  struct Box {
    float l = 0, t = 0, r = 0, b = 0;
    bool empty = true;
    void Add(const Box& o);
    void Intersect(const Box& clip);
  };

  // Mutation side.
  void MarkTag(int tag) { marked_.insert(tag); }
  void MarkFull(const char* reason) {
    fullReason_.store(reason, std::memory_order_relaxed);
    full_.store(true, std::memory_order_release);
  }

  // Walk side.
  void BeginWalk();
  // One visit of `tag` (a node may be visited more than once: <Use>, modals).
  // `local` is the node's box in the builder's current space, `outset` grows it
  // there; `unbounded` = its pixels cannot be boxed; `volatileNow` = it changes
  // every frame without a mutation (spinner, caret).
  void Record(ImpellerDisplayListBuilder builder, int tag, int parent,
              ImpellerRect local, float outset, bool unbounded, bool clipsChildren,
              bool volatileNow);
  // FP-41 readback: `tag` (an expo-blur BlurView) paints a filter of the pixels
  // ALREADY DRAWN under `local`, sampling up to `readOutset` past it. Damage
  // that reaches this read area joins all of it, so a partial frame redraws
  // every pixel the filter samples (flow/diff_context.cc AddReadbackRegion +
  // ComputeDamage). Without it a partial frame blurs a blank scratch outside
  // the damage and leaves the rest of the blur showing the old content.
  void RecordReadback(ImpellerDisplayListBuilder builder, int tag, ImpellerRect local,
                      float readOutset, bool unbounded);
  void ForceFull(const char* reason) { walkFull_ = reason; }
  // `exists(tag)`: is the tag a live scene node (unpainted live node = we
  // cannot bound it).
  template <typename Exists>
  void EndWalk(FrameDamage* out, Exists exists);

  uint64_t seq() const { return seq_; }
  // After EndWalk: may `tag` (and its subtree) paint inside `clip`, by the
  // walk just finished? True when unknown or unbounded.
  bool MayPaintInside(int tag, const Box& clip) const;

 private:
  struct Rec {
    Box own, sub;
    Box read;  // FP-41 readback area (device px), when readsBack
    bool unbounded = false, subUnbounded = false;
    bool clips = false, isVolatile = false;
    bool readsBack = false, readUnbounded = false;
    int parent = 0;
  };
  // `local` grown by `outset` through the builder's transform, plus the AA
  // fringe. False when it cannot be boxed (perspective, non-finite).
  static bool DeviceBox(ImpellerDisplayListBuilder builder, ImpellerRect local, float outset,
                        Box* out);
  // Joins every readback area the damage reaches, until nothing grows. Returns
  // a full-frame reason when a reached reader cannot be boxed.
  const char* JoinReadbacks(Box* d) const;
  using Map = std::unordered_map<int, Rec>;
  void Finish(FrameDamage* out, const std::vector<int>& unknown);

  std::unordered_set<int> marked_;
  std::atomic<bool> full_{true};
  std::atomic<const char*> fullReason_{"first_frame"};
  Map cur_, prev_;
  std::vector<int> order_;  // first-visit order of this walk
  const char* walkFull_ = nullptr;
  uint64_t seq_ = 0;
  int prevW_ = 0, prevH_ = 0;
  float prevScale_ = 0.0f;
};

template <typename Exists>
void DamageTracker::EndWalk(FrameDamage* out, Exists exists) {
  std::vector<int> unknown;
  for (int tag : marked_) {
    if (cur_.count(tag) || prev_.count(tag)) continue;
    if (exists(tag)) unknown.push_back(tag);  // live but painted in neither walk
  }
  Finish(out, unknown);
}

}  // namespace rni
