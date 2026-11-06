// See WaylandTouch.h.
#include "host/WaylandTouch.h"

#include "host/GlfwSurface.h"

#include <GLFW/glfw3.h>
#define GLFW_EXPOSE_NATIVE_WAYLAND
#include <GLFW/glfw3native.h>
#include <wayland-client.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace rni {
namespace {

struct State {
  GlfwSurface* surface = nullptr;
  wl_display* display = nullptr;
  wl_surface* target = nullptr;  // GLFW's window surface
  wl_registry* registry = nullptr;
  wl_seat* seat = nullptr;
  wl_touch* touch = nullptr;
  int32_t primary = -1;  // the touch id driving the pointer path, -1 = none
  double lastX = 0.0, lastY = 0.0;
  unsigned long downs = 0, moves = 0, ups = 0, cancels = 0, foreign = 0;
};
State g;

// --- wl_touch -------------------------------------------------------------
// Coordinates are surface-local, in surface (logical) units: the same space
// GLFW reports cursor positions in on Wayland, so they go to synthesiseTouch
// unchanged and take the one screen->points conversion every input path uses.
void TouchDown(void*, wl_touch*, uint32_t, uint32_t, wl_surface* s, int32_t id,
               wl_fixed_t fx, wl_fixed_t fy) {
  if (s != g.target) { ++g.foreign; return; }  // a decoration or another surface
  if (g.primary != -1) return;                    // a second finger
  g.primary = id;
  g.lastX = wl_fixed_to_double(fx);
  g.lastY = wl_fixed_to_double(fy);
  ++g.downs;
  std::printf("rn-impeller: wl_touch down id=%d x=%.1f y=%.1f\n", id, g.lastX, g.lastY);
  std::fflush(stdout);
  g.surface->synthesiseTouch(0, g.lastX, g.lastY);
}

void TouchUp(void*, wl_touch*, uint32_t, uint32_t, int32_t id) {
  if (id != g.primary) return;
  g.primary = -1;
  ++g.ups;
  std::printf("rn-impeller: wl_touch up id=%d x=%.1f y=%.1f\n", id, g.lastX, g.lastY);
  std::fflush(stdout);
  g.surface->synthesiseTouch(1, g.lastX, g.lastY);
}

void TouchMotion(void*, wl_touch*, uint32_t, int32_t id, wl_fixed_t fx, wl_fixed_t fy) {
  if (id != g.primary) return;
  g.lastX = wl_fixed_to_double(fx);
  g.lastY = wl_fixed_to_double(fy);
  ++g.moves;
  g.surface->synthesiseTouch(2, g.lastX, g.lastY);
}

void TouchFrame(void*, wl_touch*) {}

// The compositor took the sequence (a gesture, a lost focus). It must NOT
// fire onPress; synthesiseTouch(3) releases far outside the window.
void TouchCancel(void*, wl_touch*) {
  if (g.primary == -1) return;
  g.primary = -1;
  ++g.cancels;
  std::printf("rn-impeller: wl_touch cancel\n");
  std::fflush(stdout);
  g.surface->synthesiseTouch(3, g.lastX, g.lastY);
}

void TouchShape(void*, wl_touch*, int32_t, wl_fixed_t, wl_fixed_t) {}
void TouchOrientation(void*, wl_touch*, int32_t, wl_fixed_t) {}

const wl_touch_listener kTouch = {TouchDown,  TouchUp,    TouchMotion,     TouchFrame,
                                  TouchCancel, TouchShape, TouchOrientation};

// --- wl_seat --------------------------------------------------------------
void SeatCapabilities(void*, wl_seat* seat, uint32_t caps) {
  const bool has = (caps & WL_SEAT_CAPABILITY_TOUCH) != 0;
  if (has && g.touch == nullptr) {
    g.touch = wl_seat_get_touch(seat);
    wl_touch_add_listener(g.touch, &kTouch, nullptr);
    std::printf("rn-impeller: wl_touch bound\n");
    std::fflush(stdout);
  } else if (!has && g.touch != nullptr) {
    // The touchscreen went away (hot-unplug). Drop any sequence in flight.
    TouchCancel(nullptr, g.touch);
    wl_touch_destroy(g.touch);
    g.touch = nullptr;
    std::printf("rn-impeller: wl_touch released (seat lost touch)\n");
    std::fflush(stdout);
  }
}
void SeatName(void*, wl_seat*, const char*) {}
const wl_seat_listener kSeat = {SeatCapabilities, SeatName};

// --- wl_registry ----------------------------------------------------------
void RegistryGlobal(void*, wl_registry* reg, uint32_t name, const char* iface, uint32_t version) {
  if (g.seat != nullptr || std::strcmp(iface, wl_seat_interface.name) != 0) return;
  // v5 covers down/up/motion/frame/cancel; shape/orientation (v6) are unused.
  const uint32_t v = std::min<uint32_t>(version, 5);
  g.seat = static_cast<wl_seat*>(wl_registry_bind(reg, name, &wl_seat_interface, v));
  wl_seat_add_listener(g.seat, &kSeat, nullptr);
}
void RegistryRemove(void*, wl_registry*, uint32_t) {}
const wl_registry_listener kRegistry = {RegistryGlobal, RegistryRemove};

}  // namespace

bool WaylandTouchAttach(GlfwSurface* surface, GLFWwindow* window) {
  if (glfwGetPlatform() != GLFW_PLATFORM_WAYLAND) return false;
  const char* off = std::getenv("RNI_WAYLAND_TOUCH");
  if (off != nullptr && off[0] == '0') {
    // The gate's negative arm: same binary, listener never attached.
    std::printf("rn-impeller: wayland_touch disabled (RNI_WAYLAND_TOUCH=0)\n");
    std::fflush(stdout);
    return false;
  }
  if (g.registry != nullptr) return true;
  g.surface = surface;
  g.display = glfwGetWaylandDisplay();
  g.target = glfwGetWaylandWindow(window);
  if (g.display == nullptr || g.target == nullptr) {
    std::printf("rn-impeller: wayland_touch unavailable (no wl_display/wl_surface from GLFW)\n");
    std::fflush(stdout);
    return false;
  }
  g.registry = wl_display_get_registry(g.display);
  wl_registry_add_listener(g.registry, &kRegistry, nullptr);
  // One roundtrip delivers the globals (binds the seat), the second the seat's
  // capabilities (binds wl_touch). A touchscreen that appears later arrives
  // as a capabilities event through GLFW's own dispatch.
  wl_display_roundtrip(g.display);
  wl_display_roundtrip(g.display);
  std::printf("rn-impeller: wayland_touch attached seat=%d touch=%d\n", g.seat != nullptr,
              g.touch != nullptr);
  std::fflush(stdout);
  return true;
}

void WaylandTouchDetach() {
  if (g.registry == nullptr) return;
  std::printf("rn-impeller: wayland_touch downs=%lu moves=%lu ups=%lu cancels=%lu foreign=%lu\n",
              g.downs, g.moves, g.ups, g.cancels, g.foreign);
  std::fflush(stdout);
  if (g.touch != nullptr) wl_touch_destroy(g.touch);
  if (g.seat != nullptr) wl_seat_destroy(g.seat);
  wl_registry_destroy(g.registry);
  g = State{};
}

}  // namespace rni
