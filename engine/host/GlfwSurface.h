// GlfwSurface — a REAL on-screen window: GLFW (X11/EGL) + Impeller wrapping
// the window's default framebuffer.
//
// Peer of HeadlessSurface, same contract (init / context / surface /
// typography / width / height / drawDisplayList / readPixels), plus the
// window-lifecycle calls HeadlessSurface has no use for: pollEvents(),
// shouldClose(), present(). Built from tools/window-spike.sh, which proved
// the whole chain (GLFW -> X11/Xwayland -> EGL/GLES -> Impeller GL context ->
// ImpellerSurfaceCreateWrappedFBONew -> glfwSwapBuffers) works on this host.
//
// ⛔ THE FBO IS 0, NOT AN OFFSCREEN ONE. HeadlessSurface allocates its own
// texture+FBO because there is no window to draw into; here GLFW's own
// context already has a window-system-provided default framebuffer, and that
// IS what ImpellerSurfaceCreateWrappedFBONew wraps (see example_gl.c:55-56 —
// fbo id 0u). readPixels() therefore binds framebuffer 0, not a private one.
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "host/Pixel.h"
#include "impeller.h"

#if defined(__APPLE__)
// macOS has no system EGL; the windowed path builds an ANGLE display/context
// itself and attaches it to the Cocoa view's layer. Those handles have to live
// for the surface's lifetime, so they are members here. See GlfwSurface.cpp.
#include <EGL/egl.h>
#endif

struct GLFWwindow;

namespace rni {

class GlfwSurface {
 public:
  ~GlfwSurface();

  // Returns false and fills `error` rather than aborting, matching
  // HeadlessSurface's contract.
  bool init(int width, int height, std::string* error);

  ImpellerContext context() const { return context_; }
  ImpellerSurface surface() const { return surface_; }
  ImpellerTypographyContext typography() const { return typography_; }
  int width() const { return width_; }
  int height() const { return height_; }

  // ⛔ width()/height() ARE PIXELS; THESE ARE POINTS.
  // glfwCreateWindow takes screen coordinates (points) and
  // glfwGetFramebufferSize reports pixels; on a Retina display the second is
  // twice the first. Both are recorded at init so the host can derive the
  // backing scale instead of assuming 1.0 — see host/PointScale.h.
  int pointWidth() const { return pointWidth_; }
  int pointHeight() const { return pointHeight_; }

  // ⛔ SCALE IS DETECTED ONCE AT init(). THIS IS HOW IT STOPS BEING ONCE.
  // Until now nothing in this class observed the window after creation:
  // glfwSetFramebufferSizeCallback was absent from the whole tree (measured
  // 2026-09-04). That makes the Retina fix correct at startup and wrong after
  // the first resize or the first drag to a monitor with a different backing
  // scale, which is the case no startup screenshot can catch because every
  // startup screenshot is taken before it. RN does not stop at detection
  // either: iOS listens on didUpdateDimensions, Android on configuration
  // change.
  //
  // The callback runs on the event thread inside glfwPollEvents, so it does
  // the cheap part (re-read both sizes, raise a flag) and nothing else. The
  // frame loop calls consumeDirty() and owns the expensive part: reallocating
  // the Impeller surface and re-driving the layout. Doing GL work from the
  // callback would race the paint that is already in flight.
  bool consumeDirty();

  // ⛔ consumeDirty() IS UNREACHABLE WHILE THE USER IS DRAGGING THE WINDOW.
  // On macOS, holding the mouse on a window edge puts AppKit into a MODAL
  // resize loop inside -[NSWindow sendEvent:]. glfwPollEvents() does not
  // return until the drag ENDS, so the framebuffer-size callback above raises
  // dirty_ many times and the frame loop — the only consumer — is blocked the
  // whole time. The app therefore repaints exactly once, on mouse release.
  //
  // glfwSetWindowRefreshCallback is the one escape hatch: GLFW invokes it from
  // INSIDE that modal loop (cocoa_window.m -drawRect:/-updateLayer ->
  // _glfwInputWindowDamage). So the handler installed here must not merely
  // mark state — it has to apply the resize AND render AND present a frame,
  // because the consumer that would otherwise do so cannot run.
  //
  // Cross-platform note: this callback is not darwin-only plumbing. X11 raises
  // it on Expose and Win32 on WM_PAINT, so on those platforms it fires on
  // damage/exposure rather than continuously mid-drag (Win32's WM_ENTERSIZEMOVE
  // modal loop pumps WM_PAINT the same way). The handler must therefore be
  // safe to call at arbitrary times, and idempotent when nothing changed —
  // which it is, because consumeDirty() returns false when the geometry is
  // unchanged and a repaint of identical content is a no-op to the user.
  void setRefreshHandler(std::function<void()> handler);

  // ⛔ NOTHING IN THE WINDOWED PATH COULD DELIVER A PRESS BEFORE THIS.
  // The input tier (SceneGraph::hitTest -> retained EventEmitter ->
  // TouchEventEmitter) has been correct and gated since P9, but its ONLY
  // caller was the headless `--tap X,Y` probe in main(), which runs past the
  // end of RunWindowed and never executes in `--window` mode. Measured
  // 2026-09-09: glfwSetMouseButtonCallback and glfwSetCursorPosCallback
  // appeared ZERO times in the whole tree. No callback was registered, and
  // nothing in the windowed path would have called one.
  //
  // That is the reason HostApp's onPress handlers are inert on screen while
  // tools/ci-input.sh is green: the gate exercises the half of the path that
  // works. An absent registration is indistinguishable from a broken hit test
  // from the outside, so it is stated here in the header rather than left to
  // be rediscovered.
  //
  // ⛔ THE HANDLER RECEIVES LAYOUT POINTS, NOT WHAT GLFW REPORTED.
  // glfwGetCursorPos yields SCREEN COORDINATES; dispatchTouch wants layout
  // points. The conversion (host/PointScale.h CursorPointsFromScreen) happens
  // in ONE place — inside this class, at the callback — so no caller can
  // forget it, and so the pointScale a resize changed is the one that applies.
  // Doing it in the host would put the factor-of-two on the caller's side of
  // the boundary, where a second caller would get it wrong independently.
  //
  // `down` distinguishes press from release: the host maps that to
  // TouchPhase::Down/Up. Buttons other than the left one are not forwarded;
  // there is no RN touch concept for them.
  void setMouseButtonHandler(std::function<void(float x, float y, bool down)> handler);

  // The effective layout scale, kept in sync by the host on every resize so the
  // cursor conversion cannot drift from the painter's root transform. Set from
  // the SAME DeriveWindowPointScale result the layout uses; see the host's
  // applyResizeIfDirty.
  void setPointScale(float scale) { pointScale_ = scale > 0.0f ? scale : 1.0f; }

  // Synthesises a left button press+release at a SCREEN-COORDINATE point,
  // entering the exact same conversion and handler the real GLFW callback
  // does. Exists for the same reason requestSize() does: a windowed input
  // path is otherwise only testable by a human with a mouse.
  //
  // ⚠️ This is NOT proof the GLFW callback is registered — it calls the
  // handler directly. tools/ci-window-input.sh therefore uses it only for the
  // coordinate assertions and drives a REAL XTest pointer click for the
  // registration assertion. See that gate's header.
  void synthesiseClick(double screenX, double screenY);

  // Drives a resize from inside the process, for gates. Produces the SAME
  // framebuffer-size callback a user drag produces; it is the identical code
  // path entered from a different caller. There is no headless way to make a
  // window manager resize a window, so without this the feature is only
  // testable by a human with a mouse, which is not a gate.
  void requestSize(int pointW, int pointH);

  // ⛔ WRAP EVERY PAINT IN ONE OF THESE, NOT JUST THE REFRESH CALLBACK'S.
  // The reentrancy this guards is not refresh-re-entering-refresh. It is:
  //   any paint -> present -> eglSwapBuffers -> CAMetalLayer update
  //     -> -[NSView updateLayer] -> _glfwInputWindowDamage
  //     -> the window-refresh callback -> a SECOND paint
  // The frame loop's own paint can enter that chain just as the callback's
  // can, so a flag raised only inside the callback watches one of the two
  // ways in. Scoping it around every paint is what makes the flag mean
  // "a paint is on the stack" rather than "we are inside the refresh
  // handler". Re-entry is DROPPED, not queued: the paint already on the
  // stack is producing a frame for the current geometry, so the frame the
  // re-entrant call would produce is one the outer call is about to present
  // anyway.
  //
  // RAII rather than a bare set/clear pair because paintFrame() has early
  // returns; a manual clear would be skipped on those paths and the surface
  // would then silently refuse to repaint for the rest of the process.
  class PaintScope {
   public:
    explicit PaintScope(GlfwSurface* s) : surface_(s) {
      surface_->paintInFlight_ = true;
    }
    ~PaintScope() { surface_->paintInFlight_ = false; }
    PaintScope(const PaintScope&) = delete;
    PaintScope& operator=(const PaintScope&) = delete;

   private:
    GlfwSurface* surface_;
  };

  bool paintInFlight() const { return paintInFlight_; }

  bool drawDisplayList(ImpellerDisplayList dl);

  // Reads the DEFAULT framebuffer back, already Y-flipped into top-left
  // order (same convention as HeadlessSurface::readPixels) so a screenshot
  // gate can treat both surfaces identically.
  bool readPixels(std::vector<Px>* out);

  static bool writePpm(const std::string& path, const std::vector<Px>& px,
                       int width, int height) {
    return WritePpm(path, px, width, height);
  }

  // Window-lifecycle calls HeadlessSurface has no analogue for.
  void pollEvents();
  // Blocks in GLFW's event processing for up to `timeoutSeconds`, dispatching
  // callbacks (including the window-refresh one) WITHOUT returning to the
  // caller's frame loop.
  //
  // ⛔ THIS IS THE ONLY WAY THE DRAG CONDITION IS REPRODUCIBLE OFF DARWIN.
  // The bug being fixed is "the frame loop cannot run, so nothing consumes
  // the resize". glfwSetWindowSize does NOT enter macOS's modal resize loop,
  // so a gate built on requestSize() alone proves the resize BODY works and
  // says nothing about the blocked-loop case. Stalling here reproduces the
  // defining property — event callbacks dispatch while the loop body is
  // unreachable — on every platform, which is what makes the fix gateable at
  // all. It does NOT claim to be AppKit's modal loop; see tools/ci-resize.sh.
  void waitEvents(double timeoutSeconds);
  bool shouldClose() const;
  void present();  // glfwSwapBuffers

 private:
#if defined(__APPLE__)
  // Builds the ANGLE display/context and the window surface bound to the
  // Cocoa view. Split out because it is the entire darwin-only story.
  bool initAngleForWindow(std::string* error);
#endif

  // Converts a GLFW screen-coordinate cursor position into LAYOUT POINTS and
  // hands it to mouseButtonHandler_. The ONE place the conversion happens: the
  // real GLFW mouse-button callback and synthesiseClick() both route through
  // it, so a gate driving a synthetic click exercises the same arithmetic a
  // human click does rather than a parallel copy of it.
  void dispatchCursorPoint(double screenX, double screenY, bool down);

  int width_{0};
  int height_{0};
  int pointWidth_{0};
  int pointHeight_{0};
  // Written by the GLFW callback on the event thread, read and cleared by the
  // frame loop. std::atomic rather than a plain bool because those are two
  // different threads and a torn read here shows up as a resize that is
  // silently dropped once in a while, which is far worse to debug than one
  // that never works.
  std::atomic<bool> dirty_{false};
  GLFWwindow* window_{nullptr};
  // Invoked from the GLFW window-refresh callback. Plain std::function, not
  // atomic: it is installed once before the loop starts and GLFW only calls
  // the refresh callback from the thread that is inside glfwPollEvents, which
  // is the same thread that installed it.
  std::function<void()> refreshHandler_;
  // Invoked from the GLFW mouse-button callback with LAYOUT POINTS already
  // resolved. Same threading argument as refreshHandler_: installed once
  // before the loop, called only from the thread inside glfwPollEvents.
  std::function<void(float, float, bool)> mouseButtonHandler_;
  // The layout scale the cursor conversion divides by. Mirrors the host's
  // pointScale; kept here so the conversion happens once, at the callback,
  // rather than at every caller.
  float pointScale_{1.0f};
  // ⛔ REENTRANCY GUARD, AND IT IS NOT THEORETICAL.
  // Set by PaintScope around EVERY paint (see PaintScope above), not merely
  // while inside the refresh handler. The handler paints and presents; on
  // darwin the present is eglSwapBuffers() against a CAMetalLayer, and a
  // layer update can itself drive -updateLayer:/-drawRect:, which is exactly
  // where GLFW raises window damage. That chain can be entered from the frame
  // loop's paint just as easily as from the callback's, so a flag raised only
  // inside the callback would leave the loop's paint unguarded and let a
  // paint re-enter a paint that is still on the stack, mid-Impeller-display-
  // list. Re-entry is dropped rather than queued: the outer paint is already
  // producing a frame for the current geometry.
  bool paintInFlight_{false};
#if defined(__APPLE__)
  EGLDisplay display_{EGL_NO_DISPLAY};
  EGLSurface eglSurface_{EGL_NO_SURFACE};
  EGLContext eglContext_{EGL_NO_CONTEXT};
#endif
  ImpellerContext context_{nullptr};
  ImpellerSurface surface_{nullptr};
  ImpellerTypographyContext typography_{nullptr};
};

}  // namespace rni
