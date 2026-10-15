// FP-18: the windowed RASTER half of partial repaint.
//
// Model: Flutter's Impeller partial repaint on Metal (impeller/renderer/backend/
// metal/surface_mtl.mm: a clipped frame renders into an offscreen and is blitted
// onto the drawable, which still holds the previous frame outside the clip; the
// drawable's lag is tracked per texture in shell/gpu/gpu_surface_metal_impeller.mm).
//
// Why an offscreen root and not EGL_BUFFER_PRESERVED: the interop API wraps a
// GL framebuffer with LoadAction::kClear (impeller/renderer/backend/gles/
// surface_gles.cc WrapFBO) and RenderPassGLES clears with the scissor disabled,
// so any Impeller draw into the window framebuffer wipes all of it. The previous
// frame therefore lives in our own texture R (always one frame behind = buffer
// age 1, no per-buffer damage history needed):
//   full    the item's list -> R
//   partial the clipped list -> scratch S (full size: Impeller clears it, the
//           clip limits the draw), blit the damage rect S -> R
//   then    blit R -> window framebuffer 0, present.
// Linux (EGL + GLES3) only; darwin and win32 report supported=0 (FP-19).
#pragma once

#include <cstdint>

#include "host/FrameItem.h"
#include "impeller.h"

namespace rni {

class PartialRepaint {
 public:
  struct Stats {
    uint64_t frames = 0, partial = 0, full = 0, noChange = 0, baseMismatch = 0, failed = 0;
    long long px = 0, surfacePx = 0;
    uint64_t verified = 0, verifyMismatchFrames = 0;
    long long verifyMaxPx = 0;
  };

  // GL thread, context current: true when this build and the window
  // framebuffer (single-sampled) can take blits. Prints `partial_repaint_init`.
  bool Init(bool requested);
  bool enabled() const { return enabled_; }

  // GL thread. Draws `item` into R (in full or through its damage), blits R
  // to the window framebuffer. False on any GL / Impeller failure.
  bool Draw(ImpellerContext ctx, FrameItem& item);
  // GL thread, before the context goes away.
  void Release();
  void PrintSummary() const;

 private:
  struct Target {
    unsigned tex = 0, fbo = 0, ds = 0;
    int allocW = 0, allocH = 0;  // storage
    ImpellerSurface surface = nullptr;
    int surfW = 0, surfH = 0;  // what `surface` wraps (<= alloc)
  };
  bool Ensure(ImpellerContext ctx, Target& t, int w, int h, bool exact);
  void Free(Target& t);
  bool DrawInto(ImpellerContext ctx, Target& t, int w, int h, ImpellerDisplayList dl);
  long long Verify(ImpellerContext ctx, FrameItem& item, int w, int h);
  void Log(const FrameItem& item, const char* mode, const char* reason, long long px) const;

  bool enabled_ = false;
  bool log_ = false;     // RNI_DAMAGE_LOG=1
  bool verify_ = false;  // RNI_TEST_PARTIAL_VERIFY=1
  Target root_, scratch_, check_;  // R, S, the verify hook's full repaint
  bool rootValid_ = false;
  uint64_t rootSeq_ = 0;
  Stats stats_;
};

}  // namespace rni
