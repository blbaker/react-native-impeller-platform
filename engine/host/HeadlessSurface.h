// HeadlessSurface — surfaceless EGL + GLES3 FBO wrapped as an Impeller surface.
//
// This is the CI substrate: no window, no GPU, no X11, no display server, no
// sudo. Extracted from the P0 spike unchanged in mechanism, because every pixel
// gate in this program depends on it.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "host/Pixel.h"
#include "impeller.h"

namespace rni {

class HeadlessSurface {
 public:
  ~HeadlessSurface();

  // Returns false and fills `error` rather than aborting: the caller prints a
  // specific failure instead of the process dying with no explanation.
  bool init(int width, int height, std::string* error);

  ImpellerContext context() const { return context_; }
  ImpellerSurface surface() const { return surface_; }
  ImpellerTypographyContext typography() const { return typography_; }
  int width() const { return width_; }
  int height() const { return height_; }

  // False when init() succeeded (GL context + typography are up) but the main
  // render target could not be completed — a transient GPU-memory-pressure
  // failure, or RNI_FORCE_FBO_FAIL. The scene graph still mounts, lays out and
  // walks (the layout proof needs no pixels), so the caller emits counts and
  // exits 0 instead of aborting the whole parallel suite. surface_ is null.
  bool hasDrawSurface() const { return surface_ != nullptr; }

  bool drawDisplayList(ImpellerDisplayList dl);

  // Reads the framebuffer back, ALREADY Y-FLIPPED into top-left order.
  // glReadPixels' origin is bottom-left while Impeller draws top-left; every
  // probe would otherwise read the wrong row and the renderer would get blamed.
  bool readPixels(std::vector<Px>* out);

  // Writes a binary PPM (P6). The implementation is the SHARED one in
  // Pixel.cpp — it was a member here until the Windows port, where keeping it
  // would have forced the Windows surface to duplicate it or inherit an
  // EGL-flavoured base class for a function that only formats bytes.
  static bool writePpm(const std::string& path, const std::vector<Px>& px,
                       int width, int height) {
    return WritePpm(path, px, width, height);
  }

 private:
  int width_{0};
  int height_{0};
  void* display_{nullptr};   // EGLDisplay
  void* eglContext_{nullptr};// EGLContext
  uint32_t texture_{0};
  uint32_t fbo_{0};
  // Packed depth+stencil. Impeller's non-convex fills are stencil-then-cover;
  // without this attachment they paint their bounding box. See the comment at
  // the attachment site in HeadlessSurface.cpp.
  uint32_t depthStencil_{0};
  ImpellerContext context_{nullptr};
  ImpellerSurface surface_{nullptr};
  ImpellerTypographyContext typography_{nullptr};
};

}  // namespace rni
