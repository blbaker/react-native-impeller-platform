// Wayland touch input for the GLFW host (linux-arm64 under Weston).
//
// ⛔ GLFW 3.4 HAS NO WAYLAND TOUCH. Its wl_seat listener binds the pointer and
// the keyboard only (zero references to WL_SEAT_CAPABILITY_TOUCH in its
// source), and Weston does not turn touch into pointer events the way an X
// server does. So under Weston a touchscreen tap reaches NO GLFW callback, the
// app mounts and paints, and every onPress is inert with nothing logged.
//
// This binds a SECOND wl_seat proxy on GLFW's own wl_display (default queue,
// so the events are dispatched by GLFW's glfwPollEvents/glfwWaitEvents on the
// main thread, the same thread the mouse callbacks run on) and feeds the
// primary touch point into GlfwSurface::synthesiseMouse, the same entry points
// the real mouse-button and cursor-position callbacks use. Secondary fingers
// are ignored (one RN touch, like the mouse path).
#pragma once

struct GLFWwindow;

namespace rni {
class GlfwSurface;

// Attach when GLFW is running on its Wayland backend. Returns false (and logs
// the reason) on any other platform. Safe to call once per window.
bool WaylandTouchAttach(GlfwSurface* surface, GLFWwindow* window);
void WaylandTouchDetach();

}  // namespace rni
