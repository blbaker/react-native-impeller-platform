// GlfwCocoaView — the ONE Objective-C call the darwin windowed path needs.
//
// WHY A SEPARATE .mm AND NOT objc_msgSend IN GlfwSurface.cpp
//
// ANGLE's Metal backend takes an NSView* (or CALayer*) as its
// EGLNativeWindowType. GLFW hands back an NSWindow* from glfwGetCocoaWindow(),
// so something has to call -contentView and -setWantsLayer:. Doing that with
// objc_msgSend from C++ means hand-casting the function pointer for every
// selector, which is both unreadable and ABI-fragile (the correct cast differs
// for struct-returning and float-returning selectors). Fifteen lines of real
// Objective-C is the honest version, and it keeps GlfwSurface.cpp a single
// portable translation unit shared with Linux.
//
// ⛔ setWantsLayer IS NOT OPTIONAL. An NSView is layer-BACKED only on request.
// Without it the view has no CALayer, ANGLE has nothing to attach a
// CAMetalLayer to, and eglCreateWindowSurface fails on a window that is
// visibly on screen and looks perfectly healthy — the failure reads as an EGL
// config problem rather than a Cocoa one.
#import <Cocoa/Cocoa.h>

#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3.h>
#include <GLFW/glfw3native.h>

namespace rni {

void* GlfwCocoaLayerBackedView(GLFWwindow* window) {
  NSWindow* nsWindow = glfwGetCocoaWindow(window);
  if (!nsWindow) return nullptr;
  NSView* view = [nsWindow contentView];
  if (!view) return nullptr;
  [view setWantsLayer:YES];
  return (__bridge void*)view;
}

}  // namespace rni
