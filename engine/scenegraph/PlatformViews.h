// FP-44 platform views: what one frame's walk found, handed from RECORD to the
// raster thread's embedder (host/PlatformViewEmbedder.h).
//
// Model: flow/embedded_views.h (EmbeddedViewParams = the view's box through
// its MutatorsStack) + flow/view_slicer.cc SliceViews (the RN content painted
// after a view that intersects it goes to that view's overlay surface). On a
// desktop child window we honour two mutator kinds: translate (window
// position) and rect clips (a clip window). Scale, rotate, skew and
// perspective are unsupported: the view is placed at the transformed box and
// the walk logs `platform_view_unsupported`. Rounded clips clip to their
// bounding rect. Opacity is not applied (X11 core windows have no alpha).
#pragma once

#include <algorithm>
#include <cstdint>
#include <vector>

#include "impeller.h"

namespace rni {

// Device pixels, left/top/right/bottom.
struct PvRect {
  float l = 0, t = 0, r = 0, b = 0;
  bool Empty() const { return r <= l || b <= t; }
  PvRect Intersect(const PvRect& o) const {
    PvRect x{std::max(l, o.l), std::max(t, o.t), std::min(r, o.r), std::min(b, o.b)};
    if (x.Empty()) return PvRect{};
    return x;
  }
  PvRect Union(const PvRect& o) const {
    if (Empty()) return o;
    if (o.Empty()) return *this;
    return PvRect{std::min(l, o.l), std::min(t, o.t), std::max(r, o.r), std::max(b, o.b)};
  }
};

struct PlatformViewParams {
  int tag = 0;
  PvRect box;            // finalBoundingRect: the RN box through every transform
  PvRect clip;           // intersection of the ancestors' clip rects
  bool clipped = false;  // false: no ancestor clips
  bool translateOnly = true;
  uint8_t r = 0, g = 0, b = 0;  // the solid-colour native view
  // view_slicer.cc: union of the drawn rects painted after this view (before
  // the next one) that intersect this or an earlier view; rounded out.
  PvRect overlay;
  ImpellerDisplayList overlayList = nullptr;  // owned; origin = overlay.l/t

  PvRect Visible() const { return clipped ? box.Intersect(clip) : box; }
};

// One frame's views in composition (paint) order.
struct PlatformViewFrame {
  PlatformViewFrame() = default;
  PlatformViewFrame(const PlatformViewFrame&) = delete;
  PlatformViewFrame& operator=(const PlatformViewFrame&) = delete;
  ~PlatformViewFrame() {
    for (auto& v : views) {
      if (v.overlayList) ImpellerDisplayListRelease(v.overlayList);
    }
  }
  std::vector<PlatformViewParams> views;
};

}  // namespace rni
