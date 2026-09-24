// GlfwCocoaLayer — the ONE Objective-C call the darwin windowed path needs.
//
// WHY A SEPARATE .mm AND NOT objc_msgSend IN GlfwSurface.cpp
//
// ANGLE's Metal backend takes a CALayer* as its EGLNativeWindowType. GLFW hands
// back an NSWindow* from glfwGetCocoaWindow(), so something has to call
// -contentView, -setWantsLayer: and -layer. Doing that with objc_msgSend from
// C++ means hand-casting the function pointer for every selector, which is both
// unreadable and ABI-fragile (the correct cast differs for struct-returning and
// float-returning selectors). A dozen lines of real Objective-C is the honest
// version, and it keeps GlfwSurface.cpp a single portable translation unit
// shared with Linux.
//
// ⛔ RETURN THE LAYER, NOT THE VIEW — MEASURED, NOT ASSUMED.
// Returning the NSView compiles, links, and reaches ANGLE, which then fails
// eglCreateWindowSurface with EGL_BAD_NATIVE_WINDOW. ANGLE's WindowSurfaceMtl
// bridge-casts its EGLNativeWindowType straight to CALayer* and asks whether it
// is a CAMetalLayer; an NSView answers that question incoherently. The window
// is on screen and healthy at that point, so the failure reads as an EGL config
// problem rather than a wrong-pointer-type one.
//
// ⛔ setWantsLayer IS NOT OPTIONAL. An NSView is layer-BACKED only on request.
// Without it -layer is nil, and we would hand ANGLE a null window.
#import <Cocoa/Cocoa.h>

#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3.h>
#include <GLFW/glfw3native.h>

namespace rni {

void* GlfwCocoaLayer(GLFWwindow* window) {
  NSWindow* nsWindow = glfwGetCocoaWindow(window);
  if (!nsWindow) return nullptr;
  NSView* view = [nsWindow contentView];
  if (!view) return nullptr;
  [view setWantsLayer:YES];
  return (__bridge void*)[view layer];
}

// ⛔ contentsScale DEFAULTS TO 1.0 — MEASURED, NOT ASSUMED.
// A CAMetalLayer opens at contentsScale=1 regardless of the display. On a 2x
// screen the drawableSize is then bounds×1 while glfwGetFramebufferSize reports
// bounds×2 pixels, so glViewport fills the whole framebuffer but the layer only
// presents a quarter of it — the "quarter window" read. AppKit only fixes this
// for you if the view is in a window it laid out for hi-dpi; ANGLE's layer is
// not on that path, so we set it ourselves.
//
// ⛔ USE backingScaleFactor, NOT pointScale_. contentsScale must match the
// PHYSICAL backing store or the drawable desyncs from the default framebuffer.
// pointScale_ can be overridden by --scale (PointScale.h doctrine: display is
// source of truth, --scale is override-only), so it is the wrong number here.
void GlfwCocoaSetLayerScale(GLFWwindow* window) {
  NSWindow* nsWindow = glfwGetCocoaWindow(window);
  if (!nsWindow) return;
  NSView* view = [nsWindow contentView];
  if (!view) return;
  CALayer* layer = [view layer];
  if (!layer) return;
  layer.contentsScale = [nsWindow backingScaleFactor];
}

// Reads back the layer's ACTUAL contentsScale — not the value we intended, the
// value the layer currently holds. The ENG-08 gate asserts this equals
// backingScaleFactor; reading real state (default 1.0 when nobody set it) is
// what lets the gate go red if GlfwCocoaSetLayerScale is ever dropped.
double GlfwCocoaLayerContentsScale(GLFWwindow* window) {
  NSWindow* nsWindow = glfwGetCocoaWindow(window);
  if (!nsWindow) return 0.0;
  NSView* view = [nsWindow contentView];
  if (!view) return 0.0;
  CALayer* layer = [view layer];
  if (!layer) return 0.0;
  return layer.contentsScale;
}

// The display's physical backing scale — the number contentsScale MUST match.
double GlfwCocoaBackingScale(GLFWwindow* window) {
  NSWindow* nsWindow = glfwGetCocoaWindow(window);
  if (!nsWindow) return 0.0;
  return [nsWindow backingScaleFactor];
}

// ENG item 6 — grab / grabbing cursor.
//
// GLFW 3.4 has no standard grab shape (only arrow, ibeam, crosshair, hand,
// h/v-resize, all-resize, not-allowed), so glfwCreateStandardCursor cannot
// build the open/closed hand a draggable canvas needs. AppKit ships them as
// NSCursor openHandCursor / closedHandCursor, so we set them directly.
//
// ⛔ -set, NOT -push. push/pop maintains a cursor STACK; a per-move stream that
// pushes on every enter and never balances a pop would grow the stack without
// bound. -set replaces the current cursor outright, which is the same
// semantics glfwSetCursor gives for the standard shapes and matches
// applyCursorKind's "one shape at a time, deduped by appliedCursorKind_".
void GlfwCocoaSetGrabCursor(GLFWwindow* window, bool grabbing) {
  (void)window;  // NSCursor is app-global; the window is taken for symmetry.
  NSCursor* cursor =
      grabbing ? [NSCursor closedHandCursor] : [NSCursor openHandCursor];
  [cursor set];
}

}  // namespace rni
