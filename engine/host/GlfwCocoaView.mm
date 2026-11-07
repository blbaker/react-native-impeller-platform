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
//
// forceScale > 0 (--window-hidden) pins the layer to that scale instead: the
// hidden surface is a fixed 1x canvas of --width x --height pixels whatever
// display the process happens to run on, so its drawable must not follow the
// backing store. Nobody sees the layer, so a mismatch with the display costs
// nothing.
void GlfwCocoaSetLayerScale(GLFWwindow* window, double forceScale) {
  NSWindow* nsWindow = glfwGetCocoaWindow(window);
  if (!nsWindow) return;
  NSView* view = [nsWindow contentView];
  if (!view) return;
  CALayer* layer = [view layer];
  if (!layer) return;
  layer.contentsScale = forceScale > 0 ? (CGFloat)forceScale : [nsWindow backingScaleFactor];
}

// --window-hidden: make this process one that can never be activated, before
// glfwInit runs [NSApp run] (finishLaunching). Prohibited = no Dock icon, no
// menu bar, never frontmost (LSBackgroundOnly). Accessory is the fallback if
// AppKit refuses the switch: no Dock icon, and it is only ever activated by a
// click on one of its windows or an explicit activate call, neither of which
// a never-shown window can receive.
//
// The activity assertion keeps App Nap off. A background process with no
// visible window is exactly what App Nap throttles, and the windowed tests
// exist because they need live timers.
const char* GlfwCocoaEnterBackgroundMode() {
  @autoreleasepool {
    NSApplication* app = [NSApplication sharedApplication];
    if (![app setActivationPolicy:NSApplicationActivationPolicyProhibited]) {
      [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
    static id<NSObject> activity = nil;
    if (!activity) {
      activity = [[NSProcessInfo processInfo]
          beginActivityWithOptions:(NSActivityUserInitiatedAllowingIdleSystemSleep |
                                    NSActivityLatencyCritical)
                            reason:@"rn-impeller --window-hidden test run"];
#if !__has_feature(objc_arc)
      [activity retain];
#endif
    }
    switch ([app activationPolicy]) {
      case NSApplicationActivationPolicyRegular: return "regular";
      case NSApplicationActivationPolicyAccessory: return "accessory";
      case NSApplicationActivationPolicyProhibited: return "prohibited";
    }
    return "unknown";
  }
}

// --window-hidden proof: real AppKit state, read back. on_screen is the
// window server's view (NSWindowOcclusionStateVisible), independent of
// -isVisible, which is AppKit's own flag.
void GlfwCocoaHiddenState(GLFWwindow* window, int* visible, int* onScreen, int* key,
                          int* appActive, double* layerScale) {
  NSWindow* nsWindow = glfwGetCocoaWindow(window);
  *visible = nsWindow && [nsWindow isVisible] ? 1 : 0;
  *onScreen = nsWindow && ([nsWindow occlusionState] & NSWindowOcclusionStateVisible) ? 1 : 0;
  *key = nsWindow && [nsWindow isKeyWindow] ? 1 : 0;
  *appActive = [NSApp isActive] ? 1 : 0;
  CALayer* layer = nsWindow ? [[nsWindow contentView] layer] : nil;
  *layerScale = layer ? layer.contentsScale : 0.0;
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
