#include "host/GlfwSurface.h"

#include <GLFW/glfw3.h>
#include <GLES3/gl3.h>

#include "host/PointScale.h"

#if defined(__APPLE__)
// ⛔ macOS REACHES THE WINDOW THROUGH ANGLE, NOT THROUGH SYSTEM EGL.
// Same reason HeadlessSurface has an APPLE branch: Apple ships a frozen
// desktop GL 2.1 compatibility profile and NO EGL and NO GLES at all. The
// EGL_PLATFORM_ANGLE_* tokens live only in ANGLE's own extension header, which
// is vendored beside the Khronos ones (engine/third_party/khronos).
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#endif

#include <cstdio>

namespace rni {

#if defined(__APPLE__)
// Defined in GlfwCocoaView.mm — returns the window's layer-backed CALayer,
// which is what ANGLE/Metal accepts as a native window.
void* GlfwCocoaLayer(GLFWwindow* window);
#endif

namespace {
#if defined(__APPLE__)
// ⛔ eglGetProcAddress, NOT glfwGetProcAddress, ON DARWIN.
// GLFW created the window with GLFW_NO_API here, so it owns no GL context and
// its loader resolves nothing. Impeller would get a table of null pointers and
// fail somewhere far away from the cause.
void* ProcAddr(const char* name, void*) { return (void*)eglGetProcAddress(name); }
#else
void* ProcAddr(const char* name, void*) { return (void*)glfwGetProcAddress(name); }
#endif

void GlfwErrorCallback(int error, const char* description) {
  fprintf(stderr, "rn-impeller: GLFW error (%d): %s\n", error, description);
  fflush(stderr);
}
}  // namespace

GlfwSurface::~GlfwSurface() {
  if (typography_) ImpellerTypographyContextRelease(typography_);
  if (surface_) ImpellerSurfaceRelease(surface_);
  if (context_) ImpellerContextRelease(context_);
#if defined(__APPLE__)
  if (display_ != EGL_NO_DISPLAY) {
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (eglSurface_ != EGL_NO_SURFACE) eglDestroySurface(display_, eglSurface_);
    if (eglContext_ != EGL_NO_CONTEXT) eglDestroyContext(display_, eglContext_);
    eglTerminate(display_);
  }
  if (window_) glfwDestroyWindow(window_);
#else
  if (window_) {
    glfwMakeContextCurrent(nullptr);
    glfwDestroyWindow(window_);
  }
#endif
  glfwTerminate();
}

#if defined(__APPLE__)
bool GlfwSurface::initAngleForWindow(std::string* error) {
  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };

  auto getPlatformDisplay =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
  if (!getPlatformDisplay) return fail("eglGetPlatformDisplayEXT unavailable");

  // Identical acquisition to HeadlessSurface::init — including PRINTING the
  // backend that actually took, never inferring it. A silent fallback from
  // METAL to DEFAULT renders correctly and identically, which is exactly how a
  // platform gets declared working on a path it never took.
  //
  // The cast: eglplatform.h makes EGLNativeDisplayType a plain `int` on Apple,
  // so reinterpret_cast is the one spelling valid for both integer and pointer
  // sources. See the long note in HeadlessSurface.cpp.
  struct Attempt { const char* name; EGLint type; };
  const Attempt attempts[] = {
      {"METAL", EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE},
      {"DEFAULT", EGL_PLATFORM_ANGLE_TYPE_DEFAULT_ANGLE},
  };
  for (const auto& a : attempts) {
    const EGLint dpyAttrs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, a.type, EGL_NONE};
    EGLDisplay d = getPlatformDisplay(
        EGL_PLATFORM_ANGLE_ANGLE,
        reinterpret_cast<void*>(EGL_DEFAULT_DISPLAY), dpyAttrs);
    if (d == EGL_NO_DISPLAY) continue;
    EGLint maj = 0, min = 0;
    if (!eglInitialize(d, &maj, &min)) continue;
    display_ = d;
    fprintf(stderr, "rn-impeller: ANGLE backend=%s (windowed)\n", a.name);
    break;
  }
  if (display_ == EGL_NO_DISPLAY) return fail("no ANGLE display could be initialised");

  // ⛔ EGL_WINDOW_BIT, NOT EGL_PBUFFER_BIT. This is the only substantive
  // difference from the headless config: a pbuffer config will be returned
  // happily by eglChooseConfig and then rejected by eglCreateWindowSurface.
  const EGLint cfgAttrs[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                             EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                             EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                             EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg;
  EGLint n = 0;
  if (!eglChooseConfig(display_, cfgAttrs, &cfg, 1, &n) || n != 1) {
    return fail("eglChooseConfig (window) failed");
  }
  if (!eglBindAPI(EGL_OPENGL_ES_API)) return fail("eglBindAPI failed");

  void* layer = GlfwCocoaLayer(window_);
  if (!layer) return fail("glfwGetCocoaWindow/contentView layer was null");

  eglSurface_ = eglCreateWindowSurface(display_, cfg,
                                       (EGLNativeWindowType)layer, nullptr);
  if (eglSurface_ == EGL_NO_SURFACE) {
    // PRINT THE EGL ERROR CODE. Without it this line says only "failed" and
    // gives no way to tell a bad native window (0x300B, the wrong pointer
    // type) from a bad config match (0x3005) — which cost a full build+gate
    // round trip to distinguish once already.
    fprintf(stderr, "rn-impeller: eglCreateWindowSurface eglGetError=0x%04x\n",
            eglGetError());
    return fail("eglCreateWindowSurface failed");
  }

  const EGLint ctxAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
  eglContext_ = eglCreateContext(display_, cfg, EGL_NO_CONTEXT, ctxAttrs);
  if (eglContext_ == EGL_NO_CONTEXT) return fail("eglCreateContext failed");
  if (!eglMakeCurrent(display_, eglSurface_, eglSurface_, eglContext_)) {
    return fail("eglMakeCurrent (window) failed");
  }
  return true;
}
#endif

bool GlfwSurface::init(int width, int height, std::string* error) {
  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };

  glfwSetErrorCallback(GlfwErrorCallback);
  if (!glfwInit()) return fail("glfwInit failed");

#if defined(__APPLE__)
  // ⛔ GLFW MUST NOT TRY TO MAKE A CONTEXT ON DARWIN.
  // The Linux hint below (GLFW_EGL_CONTEXT_API) asks GLFW for a SYSTEM EGL.
  // macOS has none, so GLFW refuses the window outright with
  // "EGL: Failed to find support for OpenGL" and glfwCreateWindow returns null
  // — before any of our code runs, which makes it read like an ANGLE problem
  // when ANGLE has not been consulted yet.
  //
  // GLFW_NO_API means GLFW owns the window and its event loop ONLY; we build
  // the ANGLE display/context ourselves and attach it to the view's CALayer,
  // exactly as HeadlessSurface builds its offscreen one.
  glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
#else
  // EGL context creation API, exactly as tools/window-spike.sh's
  // example_gl.c does — GLFW defaults to its native (GLX) API, and Impeller's
  // ProcAddressCallback here is glfwGetProcAddress, which only resolves GLES
  // symbols correctly when the context was created through EGL.
  glfwWindowHint(GLFW_CONTEXT_CREATION_API, GLFW_EGL_CONTEXT_API);
#endif

  window_ = glfwCreateWindow(width, height, "React Native (Impeller)", nullptr,
                             nullptr);
  if (!window_) return fail("glfwCreateWindow failed");

  int fbWidth = 0, fbHeight = 0;
  glfwGetFramebufferSize(window_, &fbWidth, &fbHeight);
  width_ = fbWidth;
  height_ = fbHeight;

  // ⛔ RECORD THE POINT SIZE TOO — THE WINDOW MAY NOT BE THE SIZE WE ASKED FOR.
  // glfwCreateWindow's arguments are a REQUEST in screen coordinates; a window
  // manager, a fullscreen constraint or a DPI policy can hand back something
  // else. Reading it back rather than reusing `width`/`height` means the
  // pixels:points ratio the host derives is a property of the window that
  // actually exists, not of the numbers we hoped for.
  int winWidth = 0, winHeight = 0;
  glfwGetWindowSize(window_, &winWidth, &winHeight);
  pointWidth_ = winWidth;
  pointHeight_ = winHeight;

  // ⛔ OBSERVE THE WINDOW, DO NOT JUST MEASURE IT ONCE.
  // Everything above runs exactly once. Without this callback the backing
  // scale and the surface size are frozen at whatever the window was when it
  // opened, so a resize paints the old geometry into a new framebuffer and a
  // drag to a 1x monitor keeps rasterising at 2x. GLFW fires this for BOTH,
  // because a scale change on the same logical window size still changes the
  // framebuffer size in pixels -- which is exactly why the framebuffer
  // callback is the right one to listen on and the window-size callback is
  // not.
  //
  // `this` reaches the callback through the window's user pointer; GLFW's C
  // API has no other channel. Only the flag is set here: see GlfwSurface.h on
  // why the GL work belongs to the frame loop.
  glfwSetWindowUserPointer(window_, this);
  glfwSetFramebufferSizeCallback(
      window_, [](GLFWwindow* w, int, int) {
        auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
        if (self) self->dirty_.store(true, std::memory_order_release);
      });

  // ⛔ MARKING DIRTY IS NOT ENOUGH DURING A LIVE DRAG — SEE GlfwSurface.h.
  // The callback above raises a flag whose ONLY consumer is the frame loop,
  // and on macOS that loop is blocked inside glfwPollEvents for the entire
  // duration of a window-edge drag (AppKit's modal resize loop runs inside
  // -[NSWindow sendEvent:]). GLFW invokes the REFRESH callback from inside
  // that same modal loop, so this is the one place a frame can be produced
  // while the drag is still in progress.
  //
  // Registered unconditionally, not under #if defined(__APPLE__): X11 raises
  // it on Expose and Win32 on WM_PAINT, where repainting on damage is
  // correct-by-definition rather than a workaround. The handler is
  // no-op-cheap when the geometry has not changed (consumeDirty() returns
  // false), so the non-darwin cost is one extra paint per exposure event, not
  // a double-paint per frame: the steady-state frame loop is untouched.
  glfwSetWindowRefreshCallback(window_, [](GLFWwindow* w) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self || !self->refreshHandler_) return;
    // Drops the callback when ANY paint is on the stack, including one the
    // frame loop started -- see PaintScope in GlfwSurface.h. The handler
    // itself raises this flag via its own PaintScope, so this still covers
    // refresh-re-entering-refresh; it just no longer covers ONLY that.
    if (self->paintInFlight_) return;
    self->refreshHandler_();
  });

  // ⛔ THE REGISTRATION THAT WAS ABSENT. Without this line the windowed app
  // mounts, lays out, paints, hit-tests correctly if asked — and no click ever
  // asks. glfwSetMouseButtonCallback was measured at ZERO occurrences in this
  // tree on 2026-09-09, which is why 13 wired onPress handlers in hostapp v5 were
  // inert while tools/ci-input.sh (headless `--tap`) stayed green.
  //
  // ⛔ THE POSITION IS READ HERE, NOT TRACKED FROM A CURSOR-MOVE CALLBACK.
  // GLFW guarantees glfwGetCursorPos is current inside the button callback,
  // and reading it at the press is strictly more correct than replaying the
  // last cursor-position event: a click delivered without an intervening move
  // (window focus click, a synthetic XTest click that warps then clicks, a
  // tap on a trackpad) has no prior move to have recorded. A cursor-position
  // callback would additionally fire hundreds of times per second to maintain
  // state nothing reads between presses.
  glfwSetMouseButtonCallback(window_, [](GLFWwindow* w, int button, int action,
                                         int /*mods*/) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self || !self->mouseButtonHandler_) return;
    // One mouse == one finger. RN has no touch phase for a right or middle
    // button, and forwarding them would deliver a press RN cannot pair.
    if (button != GLFW_MOUSE_BUTTON_LEFT) return;
    if (action != GLFW_PRESS && action != GLFW_RELEASE) return;
    double cx = 0.0, cy = 0.0;
    glfwGetCursorPos(w, &cx, &cy);
    self->dispatchCursorPoint(cx, cy, action == GLFW_PRESS);
  });

  // <ScrollView>. ENG-02. THE SECOND REGISTRATION THAT WAS ABSENT.
  // glfwSetScrollCallback was measured at ZERO occurrences in this tree before
  // this line, exactly as glfwSetMouseButtonCallback was before the block
  // above. Same failure shape: a <ScrollView> mounts, lays out, paints its
  // first screenful and never moves, and nothing logs.
  //
  // ⛔ THE POSITION IS READ AT THE EVENT, NOT TRACKED. Same argument as the
  // button callback: GLFW guarantees glfwGetCursorPos is current here, and a
  // wheel event can arrive with no preceding cursor-move to have recorded
  // (wheel over a window that just gained focus).
  glfwSetScrollCallback(window_, [](GLFWwindow* w, double /*xoffset*/,
                                    double yoffset) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self || !self->scrollHandler_) return;
    double cx = 0.0, cy = 0.0;
    glfwGetCursorPos(w, &cx, &cy);
    self->dispatchScrollPoint(cx, cy, yoffset);
  });

#if defined(__APPLE__)
  if (!initAngleForWindow(error)) return false;
#else
  glfwMakeContextCurrent(window_);
#endif

  context_ = ImpellerContextCreateOpenGLESNew(IMPELLER_VERSION, &ProcAddr, nullptr);
  if (!context_) return fail("ImpellerContextCreateOpenGLESNew returned null");

  // fbo id 0 — the window's OWN default framebuffer, not one we allocate.
  // See the file comment: this is the one real difference from
  // HeadlessSurface, which must build its own texture+FBO because it has no
  // window to draw into. True on darwin too: ANGLE's window surface presents
  // through framebuffer 0 just as a GLX/EGL window surface does.
  ImpellerISize size = {width_, height_};
  surface_ = ImpellerSurfaceCreateWrappedFBONew(
      context_, 0u, kImpellerPixelFormatRGBA8888, &size);
  if (!surface_) return fail("ImpellerSurfaceCreateWrappedFBONew returned null");

  typography_ = ImpellerTypographyContextNew();
  if (!typography_) return fail("ImpellerTypographyContextNew returned null");

  std::printf("rn-impeller: GL_RENDERER=%s\n", (const char*)glGetString(GL_RENDERER));
  std::fflush(stdout);
  return true;
}

// Reallocates the Impeller surface for the framebuffer's CURRENT size and
// re-records both sizes, so backingScale() and width()/height() describe the
// window that exists now rather than the one that opened.
//
// ⛔ THE IMPELLER SURFACE WRAPS A SIZE, NOT JUST AN FBO ID.
// FBO 0 stays valid across a resize -- it is the window's own default
// framebuffer -- but the ImpellerSurface built over it in init() carries the
// dimensions it was created with. Leaving it alone means Impeller keeps
// clipping and presenting at the OLD pixel size into a window that is now a
// different size, which reads as content pinned to a corner with garbage
// beside it. So the wrapper is released and rebuilt; the CONTEXT is not
// touched, because recreating that would drop every uploaded texture and the
// typography atlas for what is a per-drag event.
bool GlfwSurface::consumeDirty() {
  if (!dirty_.exchange(false, std::memory_order_acq_rel)) return false;
  if (!window_) return false;

  int fbWidth = 0, fbHeight = 0;
  glfwGetFramebufferSize(window_, &fbWidth, &fbHeight);
  int winWidth = 0, winHeight = 0;
  glfwGetWindowSize(window_, &winWidth, &winHeight);
  // A minimised window reports 0 in at least one axis on every platform. Zero
  // would divide the layout to nothing and ImpellerSurfaceCreateWrappedFBONew
  // would be asked for a degenerate surface, so drop the event and keep the
  // last good size; the un-minimise fires the callback again.
  if (fbWidth <= 0 || fbHeight <= 0 || winWidth <= 0 || winHeight <= 0)
    return false;
  if (fbWidth == width_ && fbHeight == height_ && winWidth == pointWidth_ &&
      winHeight == pointHeight_)
    return false;

  width_ = fbWidth;
  height_ = fbHeight;
  pointWidth_ = winWidth;
  pointHeight_ = winHeight;

#if defined(__APPLE__)
  // ANGLE's window surface tracks the CALayer, which AppKit has already
  // resized by the time this callback runs, so there is nothing to rebuild on
  // the EGL side. The viewport is ours and must follow.
#endif
  glViewport(0, 0, width_, height_);

  if (surface_) {
    ImpellerSurfaceRelease(surface_);
    surface_ = nullptr;
  }
  ImpellerISize size = {width_, height_};
  surface_ = ImpellerSurfaceCreateWrappedFBONew(
      context_, 0u, kImpellerPixelFormatRGBA8888, &size);
  return surface_ != nullptr;
}

void GlfwSurface::setRefreshHandler(std::function<void()> handler) {
  refreshHandler_ = std::move(handler);
}

void GlfwSurface::setMouseButtonHandler(
    std::function<void(float, float, bool)> handler) {
  mouseButtonHandler_ = std::move(handler);
}

void GlfwSurface::dispatchCursorPoint(double screenX, double screenY,
                                      bool down) {
  if (!mouseButtonHandler_) return;
  // ⛔ RE-READ THE SIZES, DO NOT USE THE CACHED width_/pointWidth_.
  // Those are refreshed by consumeDirty(), which the frame loop calls. During
  // a macOS modal resize drag the loop is blocked, so a click that arrives
  // just after a resize would be converted with the PREVIOUS geometry — a
  // silent off-by-a-resize that only manifests as "the first click after
  // resizing hits the wrong thing". Querying GLFW costs two syscall-free
  // reads of cached window state and removes the ordering dependency
  // entirely.
  int fbW = 0, fbH = 0, winW = 0, winH = 0;
  if (window_) {
    glfwGetFramebufferSize(window_, &fbW, &fbH);
    glfwGetWindowSize(window_, &winW, &winH);
  }
  const float px = CursorPointsFromScreen(screenX, fbW, winW, pointScale_);
  const float py = CursorPointsFromScreen(screenY, fbH, winH, pointScale_);
  mouseButtonHandler_(px, py, down);
}

void GlfwSurface::setScrollHandler(
    std::function<void(float, float, float)> handler) {
  scrollHandler_ = std::move(handler);
}

// <ScrollView>. ENG-02. The one place screen->points AND the GLFW sign flip
// happen; see the header for why the flip is not optional.
void GlfwSurface::dispatchScrollPoint(double screenX, double screenY,
                                      double glfwDy) {
  if (!scrollHandler_) return;
  // Re-read the sizes for the same reason dispatchCursorPoint does: the cached
  // values are refreshed by the frame loop, which is blocked during a modal
  // resize drag.
  int fbW = 0, fbH = 0, winW = 0, winH = 0;
  if (window_) {
    glfwGetFramebufferSize(window_, &fbW, &fbH);
    glfwGetWindowSize(window_, &winW, &winH);
  }
  const float px = CursorPointsFromScreen(screenX, fbW, winW, pointScale_);
  const float py = CursorPointsFromScreen(screenY, fbH, winH, pointScale_);
  // Wheel notches are not points. A notch of 1 that moved the list by one point
  // would be indistinguishable from a dead scroll to a human, so it is scaled
  // to a conventional line height. The sign flips here: GLFW positive = wheel
  // away = scroll UP, RN contentOffset grows going DOWN.
  constexpr float kPointsPerNotch = 40.0f;
  scrollHandler_(px, py, (float)(-glfwDy) * kPointsPerNotch);
}

void GlfwSurface::synthesiseScroll(double screenX, double screenY, double dy) {
  // Through dispatchScrollPoint, NOT scrollHandler_ directly, so the probe
  // exercises the same conversion and the same sign flip a real wheel does. A
  // synthetic path that called the handler with raw numbers would pass while
  // the real wheel scrolled backwards.
  dispatchScrollPoint(screenX, screenY, dy);
}

void GlfwSurface::synthesiseClick(double screenX, double screenY) {
  // Down then up, in that order, through the SAME conversion the callback
  // uses. RN's Pressability needs both: a lone down highlights and never
  // fires onPress.
  dispatchCursorPoint(screenX, screenY, true);
  dispatchCursorPoint(screenX, screenY, false);
}

void GlfwSurface::requestSize(int pointW, int pointH) {
  if (!window_ || pointW <= 0 || pointH <= 0) return;
  glfwSetWindowSize(window_, pointW, pointH);
}

bool GlfwSurface::drawDisplayList(ImpellerDisplayList dl) {
  if (!ImpellerSurfaceDrawDisplayList(surface_, dl)) return false;
  glFinish();
  return true;
}

bool GlfwSurface::readPixels(std::vector<Px>* out) {
  std::vector<Px> raw((size_t)width_ * height_);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glReadPixels(0, 0, width_, height_, GL_RGBA, GL_UNSIGNED_BYTE, raw.data());
  if (glGetError() != GL_NO_ERROR) return false;
  out->resize(raw.size());
  // Same Y-flip as HeadlessSurface::readPixels — glReadPixels' origin is
  // bottom-left, Impeller draws top-left.
  for (int y = 0; y < height_; ++y) {
    for (int x = 0; x < width_; ++x) {
      (*out)[(size_t)y * width_ + x] = raw[(size_t)(height_ - 1 - y) * width_ + x];
    }
  }
  return true;
}

void GlfwSurface::pollEvents() { glfwPollEvents(); }

void GlfwSurface::waitEvents(double timeoutSeconds) {
  if (timeoutSeconds <= 0.0) return;
  glfwWaitEventsTimeout(timeoutSeconds);
}

bool GlfwSurface::shouldClose() const {
  return window_ ? glfwWindowShouldClose(window_) : true;
}

void GlfwSurface::present() {
#if defined(__APPLE__)
  // glfwSwapBuffers is a NO-OP for a GLFW_NO_API window — GLFW has no context
  // to swap. The swap belongs to the EGL surface we created.
  eglSwapBuffers(display_, eglSurface_);
#else
  glfwSwapBuffers(window_);
#endif
}

}  // namespace rni
