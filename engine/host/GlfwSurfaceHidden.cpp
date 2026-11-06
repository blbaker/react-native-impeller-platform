// --window-hidden: GlfwSurface's hidden-window half (main.cpp parses the flag).
//
// The full windowed path (real run loop, timers, frame loop, the synthetic
// click/scroll/key hooks, --screenshot-after) on a window that is never shown,
// never focused and never activates the app, rendering into a fixed 1x surface
// of the window's size in screen coordinates, so a capture is exactly
// --width x --height on any display and synthetic input maps 1:1.
//
// What is NOT covered: real OS input. A window that is never on screen gets no
// mouse or keyboard events from the OS, so gates that drive XTest or other
// real input keep using --window. The synthetic hooks are the input surface.
#include "host/GlfwSurface.h"

#if defined(_WIN32)
#define GLFW_INCLUDE_NONE
#endif
#include <GLFW/glfw3.h>

#include <cstdio>

namespace rni {

#if defined(__APPLE__)
// GlfwCocoaView.mm.
void GlfwCocoaSetLayerScale(GLFWwindow* window, double forceScale);
void GlfwCocoaHiddenState(GLFWwindow* window, int* visible, int* onScreen, int* key,
                          int* appActive, double* layerScale);
#endif

// ⛔ A HIDDEN SURFACE'S PIXELS ARE ITS SCREEN COORDINATES.
// glfwGetFramebufferSize on darwin is the view's frame in BACKING pixels
// (convertRectToBacking), so it says 2x on a Retina display even when the
// layer is pinned to 1x. Every size read in GlfwSurface goes through here, so
// width_/height_, the cursor conversion (fb/win = 1) and the capture all agree
// on one 1x canvas. Off darwin the two calls already return the same numbers.
void GlfwSurface::framebufferSize(int* w, int* h) const {
  if (hidden_) {
    glfwGetWindowSize(window_, w, h);
    return;
  }
  glfwGetFramebufferSize(window_, w, h);
}

// Main thread, once per loop frame. Reads the REAL state (GLFW attributes, and
// on darwin AppKit's own view of the window, the window server's occlusion
// state and NSApp's activation), so the report cannot just echo the hints.
void GlfwSurface::sampleHidden() {
  if (!hidden_ || !window_) return;
  ++hiddenSamples_;
  int visible = glfwGetWindowAttrib(window_, GLFW_VISIBLE) ? 1 : 0;
  int focused = glfwGetWindowAttrib(window_, GLFW_FOCUSED) ? 1 : 0;
#if defined(__APPLE__)
  int nsVisible = 0, onScreen = 0, key = 0, appActive = 0;
  double layerScale = 0.0;
  GlfwCocoaHiddenState(window_, &nsVisible, &onScreen, &key, &appActive, &layerScale);
  visible |= nsVisible | onScreen;
  focused |= key;
  if (appActive) ++hiddenActiveFrames_;
  // AppKit owns a layer-backed view's layer and may re-derive its scale from
  // the display (it did on live resize, see consumeDirty). Put it back and
  // count it, so a reset is visible in the report rather than a silent 2x.
  if (layerScale != 1.0) {
    ++hiddenScaleResets_;
    GlfwCocoaSetLayerScale(window_, 1.0);
    dirty_.store(true, std::memory_order_release);
  }
#endif
  if (visible) ++hiddenVisibleFrames_;
  if (focused) ++hiddenFocusedFrames_;
}

void GlfwSurface::printHiddenReport(const char* when) const {
  if (!hidden_) return;
  int winW = 0, winH = 0;
  if (window_) glfwGetWindowSize(window_, &winW, &winH);
  std::printf(
      "rn-impeller: window_hidden %s surface_px=%dx%d points=%dx%d policy=%s "
      "samples=%d visible_frames=%d focused_frames=%d app_active_frames=%d "
      "layer_scale_resets=%d\n",
      when, width_, height_, winW, winH, hiddenPolicy_, hiddenSamples_, hiddenVisibleFrames_,
      hiddenFocusedFrames_, hiddenActiveFrames_, hiddenScaleResets_);
  std::fflush(stdout);
}

}  // namespace rni
