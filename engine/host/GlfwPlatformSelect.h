// Run-time window-system choice for the linux packages (linux matrix M1).
//
// Both linux packages carry GLFW 3.4 with the Wayland AND the X11 backends.
// Left alone, GLFW tries Wayland first, and libwayland's wl_display_connect(NULL)
// falls back to $XDG_RUNTIME_DIR/wayland-0 when WAYLAND_DISPLAY is unset. WSLg
// puts that socket in /run/user/<uid>, so an x64 gate running under its own
// Xvfb (DISPLAY=:95, WAYLAND_DISPLAY unset) opened its window on the WSLg
// desktop instead, and every XTest arm would have missed it. Measured
// 2026-10-19.
//
// Order, first match wins:
//   1. RNI_GLFW_PLATFORM=x11|wayland             forces that backend
//   2. XDG_SESSION_TYPE=wayland                  GLFW default (Wayland, then X11)
//   3. DISPLAY set                               X11: an X server is named and the
//                                                session does not declare Wayland
//   4. otherwise                                 GLFW default (Wayland, then X11)
// The board (Weston kiosk-shell, no Xwayland, no DISPLAY) lands on 4, so it is
// Wayland first. A desktop or a gate that names an X display keeps X11, which is
// what the x64 package did before M1, when it was X11-only.
#pragma once

#include <cstdlib>
#include <cstring>

namespace rni {

struct GlfwPlatformChoice {
  int hint;            // GLFW_PLATFORM_* to pass to glfwInitHint, 0 = leave GLFW's default
  const char* name;    // x11 | wayland | any
  const char* reason;  // one token, for logs and the doctor
};

inline GlfwPlatformChoice ChooseGlfwPlatform(int x11Id, int waylandId) {
  auto env = [](const char* k) -> const char* {
    const char* v = std::getenv(k);
    return (v != nullptr && v[0] != '\0') ? v : nullptr;
  };
  if (const char* p = env("RNI_GLFW_PLATFORM")) {
    if (std::strcmp(p, "x11") == 0) return {x11Id, "x11", "RNI_GLFW_PLATFORM"};
    if (std::strcmp(p, "wayland") == 0) return {waylandId, "wayland", "RNI_GLFW_PLATFORM"};
  }
  const char* session = env("XDG_SESSION_TYPE");
  if (session != nullptr && std::strcmp(session, "wayland") == 0) {
    return {0, "any", "XDG_SESSION_TYPE=wayland"};
  }
  if (env("DISPLAY") != nullptr) return {x11Id, "x11", "DISPLAY_set_session_not_wayland"};
  return {0, "any", "default_wayland_then_x11"};
}

}  // namespace rni
