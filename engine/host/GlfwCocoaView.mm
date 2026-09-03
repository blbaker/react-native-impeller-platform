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

}  // namespace rni
