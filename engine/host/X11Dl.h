// Xlib through dlopen, for builds that must load on a Wayland-only system
// (linux-arm64: the board image has no libX11 at all).
//
// Include AFTER <X11/Xlib.h>. With RNI_X11_DLOPEN unset this header is empty
// and every call below is the ordinary linked Xlib function, so the x86_64
// build is unchanged. With it set, each Xlib function the platform-view code
// calls is redirected to a pointer resolved from libX11.so.6 on first use;
// when libX11 is absent XOpenDisplay returns nullptr, which the callers
// already treat as "no X display" and degrade from.
//
// ⛔ THE LIST IS THE SET THESE FILES CALL, MEASURED, NOT GUESSED:
//   grep -ohE '\bX[A-Z][a-zA-Z0-9]+\(' host/PlatformViewsX11Gl.cpp host/PlatformViewProbeX11.cpp
// XGetPixel / XDestroyImage are Xutil.h macros through the XImage vtable and
// XShapeCombineRectangles is already dlsym'd from libXext, so none of the
// three is here. A NEW Xlib call in those files must be added below, or the
// RNI_X11_DLOPEN link fails with an undefined reference naming it (the linker
// is the check: nothing in that build links libX11).
#pragma once

#if defined(RNI_X11_DLOPEN) && RNI_X11_DLOPEN
#include <dlfcn.h>
#include <cstdio>

#include "host/OptionalLibs.h"  // the soname list (one table; --doctor reports it)

#define RNI_X11_DL_FNS(F)                                                  \
  F(XOpenDisplay) F(XCloseDisplay) F(XSync) F(XSetErrorHandler)            \
  F(XCreateWindow) F(XDestroyWindow) F(XMapWindow) F(XUnmapWindow)         \
  F(XMoveResizeWindow) F(XRestackWindows) F(XGetWindowAttributes)          \
  F(XTranslateCoordinates) F(XSetWindowBackground) F(XClearWindow)         \
  F(XGetImage)

namespace rni::x11dl {
struct Fns {
  bool ok = false;
#define RNI_X11_DL_MEMBER(n) decltype(&::n) p_##n = nullptr;
  RNI_X11_DL_FNS(RNI_X11_DL_MEMBER)
#undef RNI_X11_DL_MEMBER
};

inline const Fns& Get() {
  static const Fns fns = [] {
    Fns f;
    const ::rni::optlib::Opened o = ::rni::optlib::Open("libX11");
    void* lib = o.handle;
    if (lib == nullptr) {
      std::fprintf(stderr, "rn-impeller: x11dl libX11 unavailable (tried %s: %s); X11 platform views off\n",
                   o.tried.c_str(), o.error.c_str());
      return f;
    }
    bool all = true;
#define RNI_X11_DL_LOAD(n)                                              \
  f.p_##n = reinterpret_cast<decltype(f.p_##n)>(dlsym(lib, #n));        \
  if (f.p_##n == nullptr) {                                             \
    std::fprintf(stderr, "rn-impeller: x11dl missing symbol %s\n", #n); \
    all = false;                                                        \
  }
    RNI_X11_DL_FNS(RNI_X11_DL_LOAD)
#undef RNI_X11_DL_LOAD
    f.ok = all;
    return f;
  }();
  return fns;
}
}  // namespace rni::x11dl

// The two entry points that can run before a display exists are guarded; the
// rest are only reached with a Display* that XOpenDisplay handed out, which
// implies ok.
#define XOpenDisplay(...) \
  (::rni::x11dl::Get().ok ? ::rni::x11dl::Get().p_XOpenDisplay(__VA_ARGS__) : nullptr)
#define XSetErrorHandler(...) \
  (::rni::x11dl::Get().ok ? ::rni::x11dl::Get().p_XSetErrorHandler(__VA_ARGS__) : nullptr)
#define XCloseDisplay(...) ::rni::x11dl::Get().p_XCloseDisplay(__VA_ARGS__)
#define XSync(...) ::rni::x11dl::Get().p_XSync(__VA_ARGS__)
#define XCreateWindow(...) ::rni::x11dl::Get().p_XCreateWindow(__VA_ARGS__)
#define XDestroyWindow(...) ::rni::x11dl::Get().p_XDestroyWindow(__VA_ARGS__)
#define XMapWindow(...) ::rni::x11dl::Get().p_XMapWindow(__VA_ARGS__)
#define XUnmapWindow(...) ::rni::x11dl::Get().p_XUnmapWindow(__VA_ARGS__)
#define XMoveResizeWindow(...) ::rni::x11dl::Get().p_XMoveResizeWindow(__VA_ARGS__)
#define XRestackWindows(...) ::rni::x11dl::Get().p_XRestackWindows(__VA_ARGS__)
#define XGetWindowAttributes(...) ::rni::x11dl::Get().p_XGetWindowAttributes(__VA_ARGS__)
#define XTranslateCoordinates(...) ::rni::x11dl::Get().p_XTranslateCoordinates(__VA_ARGS__)
#define XSetWindowBackground(...) ::rni::x11dl::Get().p_XSetWindowBackground(__VA_ARGS__)
#define XClearWindow(...) ::rni::x11dl::Get().p_XClearWindow(__VA_ARGS__)
#define XGetImage(...) ::rni::x11dl::Get().p_XGetImage(__VA_ARGS__)
#endif
