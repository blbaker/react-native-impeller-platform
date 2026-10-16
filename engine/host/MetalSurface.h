// FP-21: darwin native Metal for the window (no ANGLE). Owns the CAMetalLayer
// on the GLFW window's content view and the per-frame CAMetalDrawable.
// Models flutter/shell/gpu/gpu_surface_metal_impeller.mm (nextDrawable ->
// SurfaceMTL::MakeFromMetalLayerDrawable -> render -> Present) and
// shell/platform/darwin/ios/ios_surface_metal_impeller.mm (layer setup:
// framebufferOnly NO so the last texture stays readable, drawableSize per frame).
// Threads: Attach/InLiveResize on main (AppKit); everything else on raster.
#pragma once

#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "host/Pixel.h"
#include "impeller.h"

struct GLFWwindow;

namespace rni {

class MetalSurface {
 public:
  MetalSurface();
  ~MetalSurface();

  // Main thread. CAMetalLayer as the view's layer: BGRA8, framebufferOnly NO,
  // contentsScale = backing scale. Prints `metal_layer ...` read back from it.
  bool Attach(GLFWwindow* window, std::string* error);
  // Main thread. Re-assert contentsScale (AppKit resets it on a live resize)
  // and sample NSWindow.inLiveResize for the raster side.
  void SyncFromWindow();
  // Main thread. GLFW raises its refresh callback only from the content view's
  // updateLayer, which AppKit never calls on a layer-HOSTING view (ours). So a
  // resize marks damage, and a main run-loop observer (common modes: it also
  // runs inside AppKit's modal live-resize loop) calls `onDamage` before the
  // loop sleeps, which is when AppKit's display cycle would have.
  void SetDamageHandler(std::function<void()> onDamage);
  void MarkDamage();
  // Raster thread. ImpellerContextCreateMetalNew on the layer's device.
  ImpellerContext CreateContext();
  // Raster thread. drawableSize for the next frame (the tree's pixel size).
  void SetDrawableSize(int w, int h);
  // Raster thread. nextDrawable -> wrap -> draw. The drawable is held until
  // Present() (or the next Draw/Release drops it unpresented).
  bool Draw(ImpellerContext context, ImpellerDisplayList dl);
  // Raster thread. Reads the CURRENT (not yet presented) drawable's texture,
  // top-left origin, RGBA. False when there is no drawable.
  bool ReadPixels(std::vector<Px>* out, int* w, int* h);
  // Raster thread. Presents and drops the drawable. During a live resize the
  // layer presents with the CA transaction (FlutterMetalLayer / SurfaceMTL).
  // FP-27: onDisplayed(presentedUs) runs on Metal's thread once the drawable
  // is on screen (MTLDrawable addPresentedHandler, presentedTime -> steady
  // clock us; 0 = the drawable was never displayed).
  void Present(std::function<void(int64_t presentedUs)> onDisplayed = nullptr);
  // Main thread. The CGDirectDisplayID of the window's screen (0 = unknown).
  uint32_t DisplayId() const;
  // Raster thread. CAMetalLayer.displaySyncEnabled (the swap interval).
  void SetDisplaySync(bool on);
  void Release();
  int presents() const;
  int transactionPresents() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace rni
