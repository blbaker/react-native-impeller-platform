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
struct GLFWcursor;

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
  // TouchPhase::Down/Up.
  //
  // ⛔ ITEM 6: ONLY THE LEFT BUTTON EVER REACHES THIS HANDLER, STILL.
  // Right/middle/back/forward now reach JS too, but through
  // setExtraButtonHandler below, NEVER through here — there is no RN touch
  // concept for them (no onPress, no focus/caret change), and routing them
  // through this handler would be the exact regression M3 of
  // tools/mutation-verify-mouse-buttons.sh exists to catch (a non-left press
  // starting a touch). Left's behaviour is BYTE-IDENTICAL to before item 6.
  void setMouseButtonHandler(std::function<void(float x, float y, bool down)> handler);

  // desktop-input-gap item 6. Event for a right/middle/back/forward press or
  // release, delivered in LAYOUT POINTS through the SAME one-place
  // conversion dispatchCursorPoint uses. No RN touch concept applies to
  // these buttons: main.cpp routes every one straight to
  // FabricHost::dispatchPointerButton and NEVER to
  // beginTouchCapture/endTouchCapture/focusTextInputAt — see
  // setMouseButtonHandler above for why that separation is load-bearing.
  struct ExtraButtonEvent {
    float x{0.0f};
    float y{0.0f};
    bool down{false};
    // W3C `button`: 1 middle, 2 right, 3 back, 4 forward. 0 (left) never
    // appears here.
    int button{0};
    // W3C `buttons` bitmask AFTER this event is applied: 1 left, 2 right,
    // 4 middle, 8 back, 16 forward. Shared with the left button's bitmask —
    // see lastMods()/heldButtonsMask() below — so a left press while a right
    // press is held reports buttons=3, not 1.
    int buttons{0};
    // W3C `detail`: consecutive click count for THIS button, same 500ms /
    // 4px rule as item 4b's left-button clickCount_, but tracked
    // independently per button so a right double-click cannot complete a
    // left double-click or vice versa.
    int clickCount{1};
    bool shift{false};
    bool ctrl{false};
    bool alt{false};
    bool meta{false};
  };
  // Fires for GLFW_MOUSE_BUTTON_RIGHT/MIDDLE/4/5 press and release (and for
  // a Ctrl+left press on __APPLE__, remapped to RIGHT before this fires —
  // see the callback in the .cpp). Never fires for a plain left press.
  void setExtraButtonHandler(std::function<void(const ExtraButtonEvent&)> handler);

  // The held-button bitmask (1 left, 2 right, 4 middle, 8 back, 16 forward),
  // valid inside EITHER mouse handler. Read by main.cpp to fill in `buttons`
  // on the LEFT button's own new W3C pointer events (see dispatchCursorPoint
  // in the .cpp); the extra-button path already gets it via ExtraButtonEvent.
  int heldButtonsMask() const { return heldButtons_; }

  // item 6. Full modifier state as of the most recent press OR release of
  // ANY button, left included — unlike lastPressShift() above (item 4b),
  // which freezes at PRESS time for the selection/click-count logic that
  // predates this item, this updates on every call so a RELEASE event (e.g.
  // onPointerUp, onClick) reports the modifiers live at that moment.
  struct Mods {
    bool shift{false};
    bool ctrl{false};
    bool alt{false};
    bool meta{false};
  };
  Mods lastMods() const { return lastMods_; }

  // <ScrollView>. ENG-02. Wheel/trackpad scroll, delivered as LAYOUT POINTS at
  // the cursor's LAYOUT POINT position -- the same conversion, in the same one
  // place, as the mouse button handler above, for the same reason.
  //
  // ⛔ dx/dy ARE INVERTED RELATIVE TO GLFW HERE, DELIBERATELY.
  // GLFW reports yoffset POSITIVE when the wheel is pushed away from the user
  // (scroll up) and xoffset POSITIVE when the wheel/trackpad pushes right. RN's
  // contentOffset grows as you move DOWN and RIGHT a list. Passing GLFW's sign
  // straight through gives a list that scrolls the wrong way -- which is a fully
  // functional scroll implementation that every user calls broken, and which no
  // assertion about "did the offset change" can catch. Both flips happen at this
  // boundary so the real callback and the synthetic probe path share them.
  //
  // ⚠️ dx IS CARRIED, NOT DROPPED. The host used to (void)scrollDx and this
  // handler was y-only, so a horizontal wheel or a horizontal ScrollView could
  // never move: the X delta died here, before the scene graph ever saw it. The
  // axis decision itself lives in SceneGraph::scrollBy (content-overflow, not
  // the prop); the host's job is only to deliver BOTH deltas intact.
  void setScrollHandler(
      std::function<void(float x, float y, float dx, float dy)> handler);

  // ENG-09 hover/cursor. Installed by the host; called with LAYOUT POINTS (the
  // same one-place conversion the button and scroll handlers use) on every
  // cursor MOVE. The host routes it into FabricHost::dispatchHover. Return
  // value is the cursor kind the host resolved for the point (0 arrow, 1 hand,
  // 2 ibeam); this class applies it to the window via glfwSetCursor so the
  // shape decision lives with the hit test, not split across host and surface.
  void setHoverHandler(std::function<int(float x, float y)> handler);

  // ENG-09 hover/cursor. Installed by the host; called with no arguments when
  // the cursor LEAVES the window, so the host can clear its hovered tag. The
  // window's cursor is reset to arrow here regardless.
  void setCursorLeaveHandler(std::function<void()> handler);

  // <TextInput>. ENG-01b. Keyboard delivery, the SAME registration gap the
  // mouse/scroll/cursor callbacks each closed in turn: glfwSetCharCallback and
  // glfwSetKeyCallback were measured at ZERO occurrences in this tree before
  // this. Without them a focused field paints its caret and never accepts a
  // keystroke -- every one of the ~20 HostApp v5 fields is a dead box.
  //
  // TWO callbacks, deliberately:
  //   - the CHAR handler receives a decoded Unicode codepoint (GLFW's
  //     glfwSetCharCallback), which is the ONLY correct source of a typed
  //     character: it honours the keyboard layout and dead keys, whereas
  //     mapping GLFW_KEY_* to ASCII hardcodes a US QWERTY layout.
  //   - the KEY handler (below) receives EVERY key, including the control
  //     keys that never reach the char callback at all.
  void setCharHandler(std::function<void(unsigned int codepoint)> handler);

  // desktop-input-gap P0 item 1. Full keyboard forwarding: every key
  // press/repeat/release, with modifiers and a scancode, translated to W3C
  // `key`/`code` strings HERE -- the only TU with <GLFW/glfw3.h> in scope --
  // so the host never names a GLFW symbol. Until this, the key callback
  // (GlfwSurface.cpp ~line 470) forwarded ONLY Backspace/Enter press/repeat
  // and silently dropped every other key, every release, and every modifier
  // except Shift. That made Escape/Delete/arrows/Tab/letters-while-not-typing
  // and ctrl/alt/meta/capsLock all invisible to JS: a <View onKeyDown> could
  // never fire, and a focused TextInput's onKeyPress never saw a modifier.
  enum class KeyPhase { Down, Repeat, Up };
  struct KeyEvent {
    // W3C-shaped strings (ArrowLeft, Home, Delete, Escape, Tab, F1, "a",
    // "A", "1", ...). Built from GLFW_KEY_* plus glfwGetKeyName for the
    // layout-correct printable case; see the translation table in the .cpp.
    std::string key;
    // W3C `code` (physical position: KeyA, Digit1, ArrowLeft, ...), derived
    // from the GLFW_KEY_* token itself (layout-independent), NOT from the
    // scancode -- glfwGetKeyName gives the layout-correct *character*, which
    // is what `key` wants, but `code` names the PHYSICAL key regardless of
    // layout, so it is built from the same GLFW_KEY_* table as `key`'s
    // non-printable branch.
    std::string code;
    KeyPhase phase{KeyPhase::Down};
    bool shift{false};
    bool ctrl{false};
    bool alt{false};
    bool meta{false};       // GLFW_MOD_SUPER (Cmd on macOS, Super/Win elsewhere)
    bool capsLock{false};
    int scancode{0};
  };
  // Fires for EVERY key press, repeat AND release (release was previously
  // dropped entirely). Printable characters still do NOT come through here --
  // they arrive layout-decoded via the char handler above; this is for
  // key identity + modifiers + phase, which the char callback cannot carry.
  void setFullKeyHandler(std::function<void(const KeyEvent&)> handler);

  // Backward-compatible editing-control shape, kept ONLY so the existing
  // Backspace/Enter single-line edit path (FabricHost::dispatchKey) stays
  // byte-for-byte unchanged and ci-textedit.sh needs no edits. Derived from
  // the SAME full KeyEvent the callback above just built -- not a second,
  // independent translation -- so the two handlers cannot disagree about
  // what GLFW reported. Fires on Down/Repeat only, matching the old
  // behaviour (release was, and remains, not an edit).
  enum class EditKey { Backspace, Enter };
  void setKeyHandler(std::function<void(EditKey key, bool shift)> handler);

  // Neutral modifier set for synthesiseKey, below -- NOT a GLFW_MOD_* bitmask,
  // so a caller (main.cpp's CLI test hooks) never has to name one. GlfwSurface
  // is the only TU allowed to know GLFW_MOD_* exists.
  struct KeyMods {
    bool shift{false};
    bool ctrl{false};
    bool alt{false};
    bool meta{false};
    bool capsLock{false};
  };
  // Synthesises a key event by its W3C `key` NAME (e.g. "ArrowLeft", "a",
  // "Tab"), through the EXACT SAME reverse-lookup + dispatch path the real
  // glfwSetKeyCallback forward-translation uses (see the .cpp), for gates on
  // hosts where XTest cannot reach every modifier combination (Super is
  // refused by some window managers) or to pin a case independent of keyboard
  // layout. Returns false if `key` has no known GLFW mapping (a typo in a
  // gate, not a silent no-op). NOT proof the registration exists -- see the
  // synthesiseClick warning above, same reasoning applies: this calls the
  // handler directly.
  bool synthesiseKey(const std::string& key, KeyPhase phase,
                     const KeyMods& mods);

  // desktop-input-gap item 2a. Synthesises a CHARACTER event -- a decoded
  // Unicode codepoint -- through the exact charHandler_ callback a real
  // glfwSetCharCallback delivers, for gates typing non-ASCII (e-acute,
  // emoji) where XTest cannot easily synthesise the raw keysym. Unlike
  // synthesiseKey there is no reverse GLFW table to consult: GLFW's char
  // callback is already keyed by codepoint, so this calls charHandler_
  // directly with no translation at all. Same caveat as synthesiseKey: NOT
  // proof glfwSetCharCallback is registered, only that InsertChar's codepoint
  // handling + the dispatch plumbing downstream of it are correct. Returns
  // false if no char handler is installed.
  bool synthesiseChar(unsigned int codepoint);

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

  // <ScrollView>. ENG-02. Synthesises a wheel scroll of `dy` GLFW-convention
  // units at a SCREEN-COORDINATE point, entering the same conversion and the
  // same handler the real GLFW scroll callback does.
  //
  // ⚠️ SAME WARNING AS synthesiseClick, AND IT IS THE ONE THAT MATTERS FOR
  // ENG-02: this is NOT proof glfwSetScrollCallback is registered. It calls
  // the handler directly, so it passes with the registration deleted.
  // tools/ci-scroll.sh uses it for the offset/emitter assertions and a REAL
  // XTest button-4/5 press for the registration assertion.
  void synthesiseScroll(double screenX, double screenY, double dx, double dy);

  // ENG-09 hover/cursor. Synthesises a cursor MOVE to a SCREEN-COORDINATE
  // point, entering the exact same conversion and hover handler the real GLFW
  // cursor-position callback does, and applying the resolved cursor shape.
  // Exists for the same reason synthesiseClick does: a windowed hover path is
  // otherwise only testable by a human with a mouse.
  //
  // ⚠️ SAME WARNING AS synthesiseClick: this is NOT proof
  // glfwSetCursorPosCallback is registered -- it calls the handler directly, so
  // it passes with the registration deleted. The negative arm of the gate
  // removes the registration and asserts NO hover lines under a REAL OS motion
  // event; this hook covers the transition logic where there is no display.
  void synthesiseHover(double screenX, double screenY);

  // item 4b. One synthetic mouse event through the SAME entry points the real
  // callbacks use: op 0 = left press, 1 = left release (dispatchCursorPoint,
  // so click counting and the Shift state apply), 2 = move
  // (dispatchHoverPoint, so a move while pressed is a drag).
  void synthesiseMouse(int op, double screenX, double screenY, bool shift);

  // desktop-input-gap item 6. Synthesises ANY button (left included) with
  // FULL modifiers, through dispatchCursorPoint (button 0) or
  // dispatchExtraButton (1/2/3/4) — the SAME entry points the real GLFW
  // callback uses after the __APPLE__ Ctrl+left remap, so a synthetic gate
  // exercises identical dispatch, click counting and the buttons bitmask.
  // `w3cButton`: 0 left, 1 middle, 2 right, 3 back, 4 forward.
  void synthesiseMouseButton(int w3cButton, bool down, double screenX,
                             double screenY, bool shift, bool ctrl, bool alt,
                             bool meta);

  // item 4b. State of the most recent left PRESS, valid inside the
  // mouse-button handler. clickCount: 1 single, 2 double, 3 triple (keeps
  // counting on further quick clicks). A press counts as the next click when
  // it lands within kMultiClickMs and kMultiClickSlopPx of the previous
  // press, the same rule macOS (NSEvent.doubleClickInterval) and Windows
  // (GetDoubleClickTime / SM_CXDOUBLECLK) use with their default settings.
  int lastClickCount() const { return clickCount_; }
  bool lastPressShift() const { return pressShift_; }

  // ENG-09 hover/cursor. Synthesises the cursor LEAVING the window, entering
  // the same cursor-leave handler the real GLFW cursor-enter callback does.
  void synthesiseCursorLeave();

  // item 5. System clipboard, wrapping glfwGetClipboardString/
  // glfwSetClipboardString. ⛔ MAIN-THREAD ONLY, same restriction every other
  // GLFW call in this class has -- see ClipboardBridge.h for why the caller
  // (main.cpp) must only ever invoke these from the main thread, through the
  // bridge's queue or its direct getSystemNow()/setSystemNow() (both of
  // which assume they are already running on the right thread). Returns ""
  // when GLFW has nothing to report (empty clipboard, or a backend that
  // refuses UTF-8) rather than a null-deref -- glfwGetClipboardString can
  // return nullptr.
  std::string getClipboardString() const;
  void setClipboardString(const std::string& s);

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
  // P12-01: wake a thread parked in glfwWaitEventsTimeout. Thread-safe (GLFW
  // guarantees glfwPostEmptyEvent is callable from any thread); the idle-skip
  // damage wake calls this from the JS thread.
  void postEmptyEvent();
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
  void dispatchCursorPoint(double screenX, double screenY, bool down,
                           int glfwMods = 0);

  // <ScrollView>. ENG-02. Same role for scroll that dispatchCursorPoint plays
  // for clicks: the ONE place the screen->points conversion AND the GLFW sign
  // flip happen, shared by the real callback and synthesiseScroll().
  void dispatchScrollPoint(double screenX, double screenY, double glfwDx,
                           double glfwDy);

  // ENG-09 hover/cursor. The ONE place the screen->points conversion happens
  // for a hover, shared by the real cursor-position callback and
  // synthesiseHover(), exactly as dispatchCursorPoint is for clicks. Calls
  // hoverHandler_ with layout points and applies the cursor kind it returns.
  void dispatchHoverPoint(double screenX, double screenY);

  // ENG-09 hover/cursor. Sets the window cursor to the standard shape for
  // `kind` (0 arrow, 1 hand, 2 ibeam), skipping the GLFW call when it is
  // already that shape so a per-move stream does not thrash the cursor.
  void applyCursorKind(int kind);

  // desktop-input-gap P0 item 1. Builds a KeyEvent from a GLFW key/scancode/
  // action/mods tuple and fires fullKeyHandler_ + (on Down/Repeat) the
  // legacy keyHandler_. The ONE place this translation happens, shared by
  // the real glfwSetKeyCallback and synthesiseKey(), so a synthetic gate
  // exercises the identical table a real keypress does.
  void dispatchKeyEvent(int key, int scancode, int action, int mods);

  // desktop-input-gap item 6. The ONE place a right/middle/back/forward GLFW
  // button tuple becomes an ExtraButtonEvent, shared by the real
  // glfwSetMouseButtonCallback (after its __APPLE__ Ctrl+left remap) and
  // synthesiseMouseButton(). Tracks a PER-BUTTON click count (same 500ms/4px
  // rule as the left button's clickCount_ in dispatchCursorPoint, but kept
  // in its own small table so a right double-click cannot complete a left
  // double-click) and updates heldButtons_/lastMods_ before firing the
  // handler.
  void dispatchExtraButton(double screenX, double screenY, bool down,
                           int w3cButton, int glfwMods);

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
  // <ScrollView>. ENG-02. Invoked from the GLFW scroll callback with LAYOUT
  // POINTS and an RN-convention dy. Same threading argument as the two above.
  std::function<void(float, float, float, float)> scrollHandler_;
  // ENG-09 hover/cursor. Invoked from the GLFW cursor-position callback with
  // LAYOUT POINTS resolved, returning the cursor kind for the point. Same
  // threading argument as the handlers above: installed once before the loop,
  // called only from the thread inside glfwPollEvents.
  std::function<int(float, float)> hoverHandler_;
  // ENG-09 hover/cursor. Invoked from the GLFW cursor-ENTER callback when the
  // cursor leaves the window. Same threading argument.
  std::function<void()> cursorLeaveHandler_;
  // <TextInput>. ENG-01b. Keyboard handlers. Same threading discipline as the
  // pointer handlers: they run on the GLFW event thread and the host hops to the
  // JS thread inside them.
  std::function<void(unsigned int)> charHandler_;
  std::function<void(EditKey, bool)> keyHandler_;
  // desktop-input-gap P0 item 1. Full keyboard forwarding. Same threading
  // discipline as charHandler_/keyHandler_ above.
  std::function<void(const KeyEvent&)> fullKeyHandler_;
  // ENG-09 hover/cursor. The three standard cursors, created ONCE at init()
  // and destroyed in the destructor. arrowCursor_ is applied on creation and
  // whenever a point resolves to arrow; keeping the objects rather than
  // recreating per-move is why applyCursorKind is cheap. Null on a GLFW that
  // failed to create them, in which case applyCursorKind is a no-op and the
  // window keeps the default arrow.
  GLFWcursor* arrowCursor_{nullptr};
  GLFWcursor* handCursor_{nullptr};
  GLFWcursor* ibeamCursor_{nullptr};
  // The cursor kind currently applied to the window, so a per-move stream that
  // stays over one shape does not call glfwSetCursor every frame. -1 means
  // "never set", forcing the first apply through.
  int appliedCursorKind_{-1};
  // The layout scale the cursor conversion divides by. Mirrors the host's
  // pointScale; kept here so the conversion happens once, at the callback,
  // rather than at every caller.
  float pointScale_{1.0f};
  // item 4b: multi-click counting (see lastClickCount()).
  static constexpr double kMultiClickMs = 500.0;
  static constexpr double kMultiClickSlopPx = 4.0;
  double lastPressMs_{-1e9};
  double lastPressX_{0.0};
  double lastPressY_{0.0};
  int clickCount_{0};
  bool pressShift_{false};
  // desktop-input-gap item 6. Held-button bitmask (1 left, 2 right, 4 middle,
  // 8 back, 16 forward), kept current on every press/release of ANY button
  // so `buttons` on a pointer event reflects what is ACTUALLY down, not just
  // the button the current event is about -- the item 6(h) bitmask arm.
  int heldButtons_{0};
  // item 6 (__APPLE__): the current left press was a Ctrl+left secondary
  // click, so its release also goes to the right-button path.
  bool ctrlLeftIsRight_{false};
  // item 6. Modifiers as of the most recent press OR release, left included
  // -- unlike pressShift_ above (item 4b), which freezes at the left
  // button's PRESS for the click-count/selection logic that predates this
  // item, this updates on every event so a release reports live modifiers.
  Mods lastMods_{};
  // item 6. Per-button click-count state (right, middle, back, forward --
  // never left, which keeps its own clickCount_/lastPressX_/Y_/Ms_ above
  // unchanged). Indexed by W3C button number 1..4; button 0 (left) is never
  // stored here. A SEPARATE table, not a shared one, so a right click
  // immediately after a left click is never miscounted as the left button's
  // second click or vice versa.
  struct ExtraClickState {
    double lastPressMs{-1e9};
    double lastPressX{0.0};
    double lastPressY{0.0};
    int clickCount{0};
  };
  ExtraClickState extraClick_[5]{};
  // desktop-input-gap item 6. Invoked from the GLFW mouse-button callback for
  // a right/middle/back/forward press or release, and from the __APPLE__
  // Ctrl+left remap. NEVER for a plain left button -- see the header on
  // setExtraButtonHandler for why that separation matters.
  std::function<void(const ExtraButtonEvent&)> extraButtonHandler_;
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
