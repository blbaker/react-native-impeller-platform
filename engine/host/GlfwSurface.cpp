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
#include <cstdlib>

namespace rni {

#if defined(__APPLE__)
// Defined in GlfwCocoaView.mm — returns the window's layer-backed CALayer,
// which is what ANGLE/Metal accepts as a native window.
void* GlfwCocoaLayer(GLFWwindow* window);
// Defined in GlfwCocoaView.mm — sets the CALayer contentsScale to the window's
// backingScaleFactor so the drawable matches the physical framebuffer.
void GlfwCocoaSetLayerScale(GLFWwindow* window);
// Defined in GlfwCocoaView.mm — reads back the layer's actual contentsScale and
// the window's backingScaleFactor; the ENG-08 gate asserts they are equal.
double GlfwCocoaLayerContentsScale(GLFWwindow* window);
double GlfwCocoaBackingScale(GLFWwindow* window);
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
  // ENG-09 hover/cursor. Destroy the standard cursors before glfwTerminate,
  // which would otherwise leak them (GLFW frees its own on terminate, but
  // being explicit keeps the ownership obvious and survives a future move to
  // not calling glfwTerminate here).
  if (arrowCursor_) glfwDestroyCursor(arrowCursor_);
  if (handCursor_) glfwDestroyCursor(handCursor_);
  if (ibeamCursor_) glfwDestroyCursor(ibeamCursor_);
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
  //
  // ⛔ AND EGL_STENCIL_SIZE 8 IS NOT OPTIONAL. Unlike HeadlessSurface, which
  // owns its FBO and can attach a renderbuffer, this path draws into the
  // window's DEFAULT framebuffer (fbo 0) — so its stencil comes from the
  // EGLConfig and from nowhere else. Impeller fills non-convex paths with
  // stencil-then-cover; with no stencil bits the accumulate pass is a no-op and
  // the unmasked cover geometry paints the path's BOUNDING BOX. Convex fills
  // and all strokes stay pixel-exact, so this presents as "concave SVG paths
  // paint as slabs" with a clean log and no GL error. Measured 2026-09-11 on
  // the headless twin of this bug: an L, an arrowhead and a notched diamond
  // each painted 6400 (their 80x80 box) instead of 4800/4800/3000.
  const EGLint cfgAttrs[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                             EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                             EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                             EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
                             EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8, EGL_NONE};
  EGLConfig cfg;
  EGLint n = 0;
  if (!eglChooseConfig(display_, cfgAttrs, &cfg, 1, &n) || n != 1) {
    return fail("eglChooseConfig (window) failed");
  }
  if (!eglBindAPI(EGL_OPENGL_ES_API)) return fail("eglBindAPI failed");

  void* layer = GlfwCocoaLayer(window_);
  if (!layer) return fail("glfwGetCocoaWindow/contentView layer was null");

  // FRAME-ONE SCALE. HostApp.app opens on 1x and may never resize, so the resize
  // callback that drives consumeDirty() can never fire. Set contentsScale here,
  // before the first present, or frame one paints a quarter window on hi-dpi.
  GlfwCocoaSetLayerScale(window_);
  // ENG-08 OBSERVABLE. Print the layer's ACTUAL contentsScale (read back, not
  // the value we intended) beside the window's backingScaleFactor, ONCE, before
  // the first present. The gate asserts these are equal; reading real state is
  // what makes it go red if GlfwCocoaSetLayerScale is ever dropped.
  fprintf(stderr,
          "rn-impeller: layer contents_scale=%.2f backing_scale=%.2f\n",
          GlfwCocoaLayerContentsScale(window_), GlfwCocoaBackingScale(window_));

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

  // ⛔ ENG-05b: THE GLFW_SAMPLES EXPERIMENT, BEHIND A FLAG, AND EXPECTED TO DO
  // NOTHING. Set RNI_GLFW_SAMPLES=N to request an N-sample default framebuffer.
  //
  // The macOS peer proposed this as the remaining ENG-05b lead: GlfwSurface
  // draws into fbo 0, whose sample count comes from the window's framebuffer
  // config, and nothing here ever asked for multisampling. That reasoning is
  // sound and the request is now real -- but the spike already answered the
  // question it is asking, and the answer was no.
  //
  // engine/spike/aa_sample_count.cpp arm B hands Impeller a 4x MSAA
  // renderbuffer through ImpellerSurfaceCreateWrappedFBONew -- the SAME call
  // this file makes for fbo 0 -- and the readback is BYTE-IDENTICAL to the
  // single-sample arm A (FILL 3.2% partial / 50 distinct, STROKE 26.7% / 82,
  // both arms). Impeller resolves its own AA internally into an offscreen MSAA
  // texture and the sample count of the target we hand it is not consulted.
  // Re-measured on this binary 2026-09-11, unchanged.
  //
  // So this hint is kept OFF by default and exists to be FALSIFIED on hardware:
  // it costs one env var to re-run the matched pair on a real GPU, where
  // GL_EXT_multisampled_render_to_texture exists and llvmpipe's behaviour may
  // not hold. Turning it on by default would be shipping a config change with
  // no measured effect, which is how a placebo ends up load-bearing.
  if (const char* samples = std::getenv("RNI_GLFW_SAMPLES")) {
    const int n = std::atoi(samples);
    if (n > 0) {
      glfwWindowHint(GLFW_SAMPLES, n);
      // Printed, not silent: an unhonoured hint is indistinguishable from an
      // ignored one, and the whole point of the flag is knowing which.
      std::printf("rn-impeller: glfw_samples_requested=%d\n", n);
      std::fflush(stdout);
    }
  }

  // ⛔ ITEM 3: A ZERO WIDTH/HEIGHT MEANS "SIZE TO THE DISPLAY", NOT A ZERO
  // WINDOW. The host passes 0 for either axis when the user gave no --width/
  // --height (see main.cpp's widthGiven/heightGiven). glfwCreateWindow(0,0)
  // would fail or open a degenerate window, so resolve the auto axes here,
  // AFTER glfwInit (glfwGetPrimaryMonitor needs it) and BEFORE the window is
  // created. The default is ~70% of the monitor's WORK AREA -- not the full
  // monitor size, which would sit under the menu bar / taskbar -- centred in
  // that work area, with a floor near 1024x700 so a tiny or unreported monitor
  // still yields a usable window. --width/--height override per-axis: a given
  // axis arrives non-zero and is used verbatim, so `--width 800` with no
  // --height gets an 800-wide window at the derived height.
  bool autoSized = false;
  if (width <= 0 || height <= 0) {
    // Work area excludes OS chrome (macOS menu bar, Linux/Win taskbar); the
    // monitor's full mode would put our title bar off-screen on some WMs.
    int waX = 0, waY = 0, waW = 0, waH = 0;
    if (GLFWmonitor* mon = glfwGetPrimaryMonitor()) {
      glfwGetMonitorWorkarea(mon, &waX, &waY, &waW, &waH);
    }
    // A monitor that reports nothing (headless X, some VMs) must not collapse
    // the window to 0; fall back to the floor so the app still opens.
    const int kFloorW = 1024, kFloorH = 700;
    auto derive = [&](int given, int workExtent, int floor) -> int {
      if (given > 0) return given;                 // explicit axis wins
      int seventy = workExtent > 0 ? (workExtent * 7) / 10 : 0;
      return seventy > floor ? seventy : floor;    // ~70%, never below floor
    };
    width = derive(width, waW, kFloorW);
    height = derive(height, waH, kFloorH);
    autoSized = true;
    std::printf("rn-impeller: window_default size=%dx%d workarea=%dx%d\n",
                width, height, waW, waH);
    std::fflush(stdout);
  }

  window_ = glfwCreateWindow(width, height, "React Native (Impeller)", nullptr,
                             nullptr);
  if (!window_) return fail("glfwCreateWindow failed");

  // ⛔ CENTRE IN THE MONITOR WORK AREA WHEN WE CHOSE THE SIZE OURSELVES.
  // GLFW places a new window wherever the WM decides (often 0,0 -> under the
  // menu bar). When the size came from the display we also own the position:
  // centre the window in the work area so it opens where a real app would,
  // not jammed into a corner. Skipped when both axes were explicit -- a caller
  // that asked for an exact size is not asking us to move it.
  if (autoSized) {
    if (GLFWmonitor* mon = glfwGetPrimaryMonitor()) {
      int waX = 0, waY = 0, waW = 0, waH = 0;
      glfwGetMonitorWorkarea(mon, &waX, &waY, &waW, &waH);
      if (waW > 0 && waH > 0) {
        int winW = 0, winH = 0;
        glfwGetWindowSize(window_, &winW, &winH);
        glfwSetWindowPos(window_, waX + (waW - winW) / 2,
                         waY + (waH - winH) / 2);
      }
    }
  }

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
  glfwSetScrollCallback(window_, [](GLFWwindow* w, double xoffset,
                                    double yoffset) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self || !self->scrollHandler_) return;
    double cx = 0.0, cy = 0.0;
    glfwGetCursorPos(w, &cx, &cy);
    self->dispatchScrollPoint(cx, cy, xoffset, yoffset);
  });

  // ENG-09 hover/cursor. THE THIRD REGISTRATION THAT WAS ABSENT.
  // glfwSetCursorPosCallback was measured at ZERO occurrences in this tree
  // before this line (see the header's P9 note, which recorded it absent
  // alongside the mouse-button one). Same failure shape as clicks and scroll:
  // pointerenter/leave and the cursor shape have been implementable in
  // FabricHost and paintable all along, and nothing moved the mouse. A view
  // with an onPointerEnter hover style would mount, paint its resting state
  // and never light up, and no line would log.
  //
  // ⛔ UNLIKE THE BUTTON CALLBACK, THE POSITION IS THE CALLBACK'S ARGUMENT.
  // glfwSetCursorPosCallback delivers x/y directly, so there is no
  // glfwGetCursorPos here -- the argument IS the current position, by
  // definition. dispatchHoverPoint does the one-place screen->points
  // conversion, exactly as the click and scroll paths do.
  glfwSetCursorPosCallback(window_, [](GLFWwindow* w, double x, double y) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self || !self->hoverHandler_) return;
    self->dispatchHoverPoint(x, y);
  });

  // ENG-09 hover/cursor. THE OTHER HALF: clear the hovered control when the
  // cursor LEAVES the window. Without this a control the mouse was over when
  // it exited the window stays visually hovered forever -- glfwSetCursorPos
  // stops firing at the edge, so the last hovered tag never gets its
  // pointerleave. GLFW_TRUE on enter, GLFW_FALSE on leave; only the leave is
  // acted on (an enter's first move fires the position callback anyway).
  glfwSetCursorEnterCallback(window_, [](GLFWwindow* w, int entered) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self) return;
    if (entered == GLFW_FALSE && self->cursorLeaveHandler_) {
      self->cursorLeaveHandler_();
      // Reset to arrow: the next window the cursor is over owns its own shape.
      self->applyCursorKind(0);
    }
  });

  // <TextInput>. ENG-01b. THE KEYBOARD REGISTRATIONS THAT WERE ABSENT.
  // glfwSetCharCallback and glfwSetKeyCallback were measured at ZERO occurrences
  // in this tree before this, exactly as the mouse/scroll/cursor callbacks each
  // were in turn. Same failure shape: a focused field paints its caret, the JS
  // has onChangeText wired, and not one keystroke ever arrives.
  //
  // The CHAR callback carries a DECODED codepoint (layout- and dead-key-aware);
  // it is the only correct source of a typed character. Control keys never reach
  // it, which is why Backspace/Enter go through the KEY callback below.
  glfwSetCharCallback(window_, [](GLFWwindow* w, unsigned int codepoint) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self || !self->charHandler_) return;
    self->charHandler_(codepoint);
  });
  // The KEY callback delivers Backspace and Enter -- not characters, so absent
  // from the char callback. GLFW_PRESS and GLFW_REPEAT both act (holding
  // Backspace should keep deleting); GLFW_RELEASE is ignored so one keypress is
  // one edit. GLFW_KEY_* is translated to the neutral EditKey enum HERE -- the
  // only place <GLFW/glfw3.h> is in scope -- so the host never sees a GLFW code.
  // Non-editing keys are dropped at this boundary, never forwarded.
  glfwSetKeyCallback(window_, [](GLFWwindow* w, int key, int /*scancode*/,
                                 int action, int mods) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self || !self->keyHandler_) return;
    if (action == GLFW_RELEASE) return;
    EditKey ek;
    if (key == GLFW_KEY_BACKSPACE) {
      ek = EditKey::Backspace;
    } else if (key == GLFW_KEY_ENTER || key == GLFW_KEY_KP_ENTER) {
      ek = EditKey::Enter;
    } else {
      return;  // not an editing control key
    }
    self->keyHandler_(ek, (mods & GLFW_MOD_SHIFT) != 0);
  });

  // ENG-09 hover/cursor. The three standard cursors, created ONCE (not per
  // move). glfwCreateStandardCursor returns null if the platform lacks the
  // shape; applyCursorKind tolerates a null by leaving the cursor unchanged,
  // so a missing hand cursor degrades to "no shape change", never a crash.
  arrowCursor_ = glfwCreateStandardCursor(GLFW_ARROW_CURSOR);
  handCursor_ = glfwCreateStandardCursor(GLFW_HAND_CURSOR);
  ibeamCursor_ = glfwCreateStandardCursor(GLFW_IBEAM_CURSOR);

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
  // ⛔ REPORT WHAT GL GRANTED, NOT WHAT WE ASKED FOR. GLFW_SAMPLES is a HINT:
  // a driver may silently hand back a single-sample config, and then "MSAA
  // changed nothing" and "MSAA was never enabled" are the same observation.
  // GL_SAMPLES on the live default framebuffer is the only honest number, and
  // it is what turns a null result into evidence.
  if (std::getenv("RNI_GLFW_SAMPLES") != nullptr) {
    GLint granted = 0;
    glGetIntegerv(GL_SAMPLES, &granted);
    std::printf("rn-impeller: glfw_samples_granted=%d\n", (int)granted);
  }
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

#if defined(__APPLE__)
  // ⛔ RE-ASSERT THE LAYER SCALE BEFORE READING THE FRAMEBUFFER, NOT AFTER.
  // ENG item 2 (Retina scale drops to 1.00 after the first resize). On a live
  // resize AppKit resets the ANGLE CAMetalLayer's contentsScale back to 1.0
  // BEFORE this callback runs, so glfwGetFramebufferSize then reports the 1x
  // point size (px==points, scale=1.00) on a 2x display -- the "rough icons /
  // text after resize" read. Setting contentsScale back to backingScaleFactor
  // first restores the 2x drawable, so the framebuffer query below reports the
  // true 2x pixel size and width_/height_ carry the physical backing again.
  // The old code set the scale AFTER the query, one frame too late.
  GlfwCocoaSetLayerScale(window_);
#endif

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

  // ANGLE's window surface tracks the CALayer, which AppKit has already
  // resized by the time this callback runs, so there is nothing to rebuild on
  // the EGL side. The viewport is ours and must follow. contentsScale was
  // already re-asserted at the TOP of this function (before the framebuffer
  // query) so the drawable is 2x again; do NOT re-assert here.
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
    std::function<void(float, float, float, float)> handler) {
  scrollHandler_ = std::move(handler);
}

// <ScrollView>. ENG-02. The one place screen->points AND the GLFW sign flip
// happen; see the header for why the flip is not optional.
void GlfwSurface::dispatchScrollPoint(double screenX, double screenY,
                                      double glfwDx, double glfwDy) {
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
  // to a conventional line height. Both signs flip here: GLFW positive-y = wheel
  // away = scroll UP, RN contentOffset grows going DOWN; GLFW positive-x = push
  // right, RN contentOffset grows going RIGHT. dx is carried through with the
  // same treatment dy gets rather than dropped, which is the whole fix -- a
  // y-only handler could never move a horizontal list.
  constexpr float kPointsPerNotch = 40.0f;
  scrollHandler_(px, py, (float)(-glfwDx) * kPointsPerNotch,
                 (float)(-glfwDy) * kPointsPerNotch);
}

void GlfwSurface::synthesiseScroll(double screenX, double screenY, double dx,
                                   double dy) {
  // Through dispatchScrollPoint, NOT scrollHandler_ directly, so the probe
  // exercises the same conversion and the same sign flip a real wheel does. A
  // synthetic path that called the handler with raw numbers would pass while
  // the real wheel scrolled backwards.
  dispatchScrollPoint(screenX, screenY, dx, dy);
}

void GlfwSurface::setHoverHandler(std::function<int(float, float)> handler) {
  hoverHandler_ = std::move(handler);
}

void GlfwSurface::setCursorLeaveHandler(std::function<void()> handler) {
  cursorLeaveHandler_ = std::move(handler);
}

// <TextInput>. ENG-01b. Keyboard handler setters.
void GlfwSurface::setCharHandler(std::function<void(unsigned int)> handler) {
  charHandler_ = std::move(handler);
}
void GlfwSurface::setKeyHandler(
    std::function<void(EditKey, bool)> handler) {
  keyHandler_ = std::move(handler);
}

// ENG-09 hover/cursor. The one place a hover's screen->points conversion
// happens; see the header. Applies the cursor shape the handler resolved so
// the shape decision rides with the hit test rather than being recomputed.
void GlfwSurface::dispatchHoverPoint(double screenX, double screenY) {
  if (!hoverHandler_) return;
  // Re-read the sizes for the same reason dispatchCursorPoint does: the cached
  // values are refreshed by the frame loop, which is blocked during a modal
  // resize drag, and a hover that arrives just after a resize must use the
  // geometry that exists now.
  int fbW = 0, fbH = 0, winW = 0, winH = 0;
  if (window_) {
    glfwGetFramebufferSize(window_, &fbW, &fbH);
    glfwGetWindowSize(window_, &winW, &winH);
  }
  const float px = CursorPointsFromScreen(screenX, fbW, winW, pointScale_);
  const float py = CursorPointsFromScreen(screenY, fbH, winH, pointScale_);
  const int kind = hoverHandler_(px, py);
  applyCursorKind(kind);
}

// ENG-09 hover/cursor. Set the window cursor for `kind`, skipping the GLFW
// call when it is already that shape so a per-move stream does not thrash it.
void GlfwSurface::applyCursorKind(int kind) {
  if (kind == appliedCursorKind_) return;
  if (!window_) return;
  GLFWcursor* c = arrowCursor_;
  if (kind == 1) c = handCursor_;
  else if (kind == 2) c = ibeamCursor_;
  // A null standard cursor (platform did not provide the shape) means "leave
  // the current cursor alone" rather than resetting to the platform default,
  // which would flicker to arrow over a hand-requesting view on such a host.
  if (!c) return;
  glfwSetCursor(window_, c);
  appliedCursorKind_ = kind;
}

void GlfwSurface::synthesiseHover(double screenX, double screenY) {
  // Through dispatchHoverPoint, NOT hoverHandler_ directly, so the probe
  // exercises the same conversion and the same cursor-apply a real move does.
  dispatchHoverPoint(screenX, screenY);
}

void GlfwSurface::synthesiseCursorLeave() {
  if (cursorLeaveHandler_) cursorLeaveHandler_();
  applyCursorKind(0);
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
