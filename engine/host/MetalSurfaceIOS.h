// iOS Phase 1 / Task 1.1: the iOS counterpart of MetalSurface (FP-21). Owns the
// CAMetalLayer of a UIView whose +layerClass is CAMetalLayer and the per-frame
// CAMetalDrawable. Same frame contract as MetalSurface: Draw (nextDrawable ->
// wrap -> draw) -> optional ReadPixels -> Present.
// Model: flutter/shell/platform/darwin/ios/ios_surface_metal_impeller.mm (layer
// setup: BGRA8, framebufferOnly NO so the drawable stays readable) and
// flutter/shell/gpu/gpu_surface_metal_impeller.mm (nextDrawable -> render -> present).
// No GLFW and no AppKit: the host app owns the view (RNIMetalLayerView below).
// Threads: Attach/SyncFromView on main (UIKit); everything else on raster.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "host/Pixel.h"
#include "impeller.h"

// Same mangling in C++ and Objective-C++ TUs (an ObjC class pointer mangles as
// a pointer to a struct of the same name).
#ifdef __OBJC__
@class UIView;
#else
struct UIView;
#endif

namespace rni {

class MetalSurfaceIOS {
 public:
  MetalSurfaceIOS();
  ~MetalSurfaceIOS();

  // Main thread. `view`'s backing layer must be a CAMetalLayer (+layerClass);
  // anything else is refused with an error, never silently re-layered. Sets
  // BGRA8, framebufferOnly NO, contentsScale = the screen's nativeScale and
  // drawableSize = bounds x scale. Prints `metal_layer ...` read back from it.
  bool Attach(UIView* view, std::string* error);
  // Main thread. Re-reads bounds and scale after a layout change (rotation,
  // split view) and resizes the drawable; *w/*h get the new pixel size.
  void SyncFromView(int* w, int* h);
  // Raster thread. ImpellerContextCreateMetalNew; the layer uses the same
  // (system default) device. NULL before Attach or without Metal.
  ImpellerContext CreateContext();
  // Raster thread. drawableSize for the next frame, in pixels.
  void SetDrawableSize(int w, int h);
  // Raster thread. nextDrawable -> wrap -> draw. The drawable is held until
  // Present() (or the next Draw/Release drops it unpresented).
  bool Draw(ImpellerContext context, ImpellerDisplayList dl);
  // Raster thread. Reads the CURRENT (not yet presented) drawable's texture,
  // top-left origin, RGBA, ordered after the draw (SDK patch 0005's
  // ImpellerSurfaceReadPixels). False when there is no drawable.
  bool ReadPixels(std::vector<Px>* out, int* w, int* h);
  // Raster thread. Presents and drops the drawable. onDisplayed(presentedUs)
  // runs on Metal's thread once the drawable is on screen (steady clock us;
  // 0 = it was never displayed). The simulator SDK has no presented handler:
  // there onDisplayed(0) runs on this thread right after the present.
  void Present(std::function<void(int64_t presentedUs)> onDisplayed = nullptr);
  // CAMetalLayer.displaySyncEnabled is macOS-only: on iOS every present is
  // display-synced. The request is recorded (displaySync()) and nothing else.
  void SetDisplaySync(bool on);
  bool displaySync() const;
  void Release();
  int presents() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace rni

#ifdef __OBJC__
#import <UIKit/UIKit.h>
// A UIView backed by a CAMetalLayer, ready for MetalSurfaceIOS::Attach.
@interface RNIMetalLayerView : UIView
@end
#endif
