// FP-44: the raster side of platform views. Model: flow/embedded_views.h
// ExternalViewEmbedder::SubmitFlutterView as the iOS embedder implements it
// (FlutterPlatformViewsController.mm submitFrame): render each overlay layer
// (the RN slice above a view, clipped to its rect, over transparent), then
// apply every view's mutators (position, clip) and z-order in the same frame
// as the background present.
//
// Linux X11 (windowed GL) is the only implementation: a view is a child window
// (clip window = the mutator stack's clip rect, content window = the box inside
// it) and an overlay is a child window with its own EGL surface, stacked above
// its view and shaped to the pixels the slice drew (X11 core windows have no
// alpha without a compositor, so the overlay is 1-bit: alpha >= 128 shows).
// NSView / HWND are not implemented: MakePlatformViewEmbedder returns null and
// SceneGraph paints the view's colour in place.
#pragma once

#include <cstdint>
#include <memory>

#include "scenegraph/PlatformViews.h"

namespace rni {

class GlfwSurface;

class PlatformViewEmbedder {
 public:
  virtual ~PlatformViewEmbedder() = default;
  // Raster thread, the frame's background drawn and its surface current,
  // before the present. `frame` may be null (no views: hide everything).
  virtual void SubmitFrame(const std::shared_ptr<PlatformViewFrame>& frame, int present,
                           uint64_t frameNumber) = 0;
  // Raster thread, after the present.
  virtual void DidPresent(int present) = 0;
  // Raster thread, before the GL context is released.
  virtual void Teardown() = 0;
  // `platform_views_summary ...` (main, after the raster thread joined).
  virtual void PrintSummary() const = 0;
};

// Main thread, after the window exists. Null where no embedder exists.
std::unique_ptr<PlatformViewEmbedder> MakePlatformViewEmbedder(GlfwSurface& surface);

}  // namespace rni
