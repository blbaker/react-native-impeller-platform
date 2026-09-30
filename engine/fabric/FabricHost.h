// FabricHost — the live Fabric renderer wired to a bridgeless ReactInstance:
// component descriptor registry, Scheduler built from a SchedulerToolbox, and a
// SurfaceHandler. The SchedulerDelegate (in the .cpp) pulls MountingTransactions
// on the JS thread and applies them to the retained SceneGraph.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "impeller.h"

namespace facebook::react {
class ComponentDescriptorProviderRegistry;
class ReactInstance;
class RuntimeScheduler;
class Scheduler;
class SchedulerDelegate;
class SurfaceHandler;
}  // namespace facebook::react

namespace rni {

class SceneGraph;
struct DisplayMetrics;

class FabricHost {
 public:
  // instance and sceneGraph must outlive this host. Installs UIManagerBinding
  // into the runtime via the Scheduler's bridgelessBindingsExecutor.
  // typography is the surface's ImpellerTypographyContext: it backs the real
  // TextLayoutManager, without which every <Text> measures 0x0 (RN's cxx stub).
  FabricHost(facebook::react::ReactInstance& instance, SceneGraph* sceneGraph,
             ImpellerTypographyContext typography, bool logMutations,
             std::shared_ptr<DisplayMetrics> displayMetrics = nullptr);
  ~FabricHost();

  // Registers and starts a surface, which triggers
  // AppRegistry.runApplication(moduleName) on the JS thread.
  //
  // width/height are DEVICE PIXELS (what the render surface allocates);
  // pointScaleFactor is how many device pixels one React point occupies.
  // The surface is constrained in POINTS = pixels / scale.
  void startSurface(const std::string& moduleName, int surfaceId, float width,
                    float height, float pointScaleFactor = 1.0f);

  // Re-constrains an ALREADY RUNNING surface to a new pixel size and scale.
  //
  // ⛔ THIS IS THE ONLY THING THAT MAKES A RESIZE VISIBLE TO THE APP.
  // startSurface constrains the layout once and there was no other entry
  // point, so a host that re-measured its window on every framebuffer change
  // could update Dimensions and the framebuffer and still leave every mounted
  // view at the geometry it had at launch. RN's own platforms re-constrain:
  // iOS through RCTSurface's setSize, Android through the SurfaceHandler the
  // ReactRootView owns. Same units as startSurface -- DEVICE PIXELS, divided
  // by the scale here -- so the two cannot drift.
  //
  // Returns false when no surface has been started, rather than crashing on a
  // null handler: a resize event that arrives before startSurface is a real
  // ordering, not a programming error.
  bool updateSurface(int surfaceId, float width, float height,
                     float pointScaleFactor = 1.0f);
  void stopSurface();

  // Touch phases, mapped to TouchEventEmitter's four touch entry points.
  enum class TouchPhase { Down, Move, Up, Cancel };

  // Hit-tests (x, y) and dispatches a touch to whatever is under it.
  // Returns the tag that received the event, or 0 if nothing did.
  //
  // ⛔ x/y ARE IN POINTS. A windowed caller holding a GLFW cursor position has
  // DEVICE PIXELS and must divide by pointScaleFactor first -- the same factor
  // the painter applies as its root transform. Getting this wrong is invisible
  // at 1x and doubles every coordinate on a retina display.
  //
  // Safe to call from the UI/event thread: it takes the SceneGraph lock to
  // resolve the target, then dispatches through the RuntimeScheduler so the
  // emitter runs on the JS thread. Calling a TouchEventEmitter directly from
  // the event thread would race the mounting transaction that owns the node.
  int dispatchTouch(TouchPhase phase, float x, float y);

  // Shared touch builder used by dispatchTouch (which hit-tests to find the
  // target) and the drag-capture path (which supplies the captured tag with no
  // hit test). `target` is a react::Tag (int32_t); 0 or a non-touch node yields
  // no dispatch and returns 0.
  int dispatchTouchToTarget(TouchPhase phase, std::int32_t target, float x,
                            float y);

  // ENG-DRAG (P0). Press-drag-release capture, the retention a PointerDispatcher
  // gives other platforms and impeller lacks. beginTouchCapture hit-tests the
  // press and remembers the tag it landed on; dispatchCapturedMove and
  // endTouchCapture then deliver Move/Up to THAT tag with NO further hit test,
  // so a drag stays on the pressed control after the cursor leaves its bounds.
  // All three take POINTS, same contract as dispatchTouch.
  //
  // beginTouchCapture returns the captured tag (0 if the press hit empty space
  // or a non-touch node -- nothing is captured then). dispatchCapturedMove and
  // endTouchCapture return the captured tag, or 0 if no press is held.
  // isTouchCaptured lets the windowed host tell a drag-move from a hover-move.
  int beginTouchCapture(float x, float y);
  int dispatchCapturedMove(float x, float y);
  int endTouchCapture(float x, float y);
  bool isTouchCaptured() const;

  // <ScrollView>. ENG-02. Applies `dy` POINTS of scroll at (x, y) in points --
  // the same coordinate space dispatchTouch takes -- and returns the tag of the
  // ScrollView that took it, or 0 if the point was over nothing scrollable.
  //
  // A non-zero return means BOTH the offset moved (or was already clamped at
  // the end) AND an onScroll was scheduled onto the JS thread. A zero means no
  // scrollable node was under the point OR the node found could not emit
  // scroll events, which is what an unregistered ScrollView looks like.
  int dispatchScroll(float x, float y, float dx, float dy);

  // ENG-09 hover/cursor. Result of a hover motion at a point.
  struct HoverResult {
    // The tag now under the cursor (0 = nothing / non-touch target).
    int tag{0};
    // The cursor shape for that tag: 0 arrow, 1 hand, 2 ibeam.
    int cursorKind{0};
    // The tag a pointerenter was dispatched to this move, or 0 if the hovered
    // tag did not change (a move within the same view).
    int entered{0};
    // The tag a pointerleave was dispatched to this move, or 0 if none.
    int left{0};
  };

  // Hit-tests (x, y) in POINTS and moves the retained hovered tag to whatever
  // is under it, dispatching pointerleave to the OLD tag and pointerenter to
  // the NEW one -- and NOTHING when the tag is unchanged, so a stream of
  // mouse-moves within one view is silent. Same coordinate contract and same
  // TouchEventEmitter downcast discipline as dispatchTouch: a hit on a
  // non-touch (e.g. unregistered) node yields no emitter, so its tag is
  // treated as "no hovered target" -- it cannot receive pointer events, and
  // pretending it is hovered would strand a leave that can never be delivered.
  HoverResult dispatchHover(float x, float y);

  // ENG-09 hover/cursor. Clears the hovered tag, dispatching pointerleave to
  // it if one was set. Called when the cursor leaves the window entirely, so a
  // control does not stay visually hovered after the mouse exits. Returns the
  // tag that was left, or 0 if nothing was hovered.
  int clearHover();

  // <TextInput>. ENG-01b. Focus the field under (x, y) in POINTS, or blur if
  // the point is over no TextInput. Returns the focused tag, or 0. Focusing
  // seeds the edit buffer from the field's value and schedules onFocus.
  // item 3: the caret goes to the glyph boundary nearest x (click-to-caret),
  // onSelectionChange fires, and clicking the already-focused field only
  // moves the caret (no re-seed, no second onFocus).
  int focusTextInputAt(float x, float y);

  // A single editing keystroke, applied to the focused field's buffer AT THE
  // PERSISTED CARET (SceneGraph::textInputCaretFor), not always at the end --
  // item 2a. `codepoint` is a full Unicode scalar value for InsertChar
  // (encoded to UTF-8 here; see FabricHost.cpp's Utf8Encode), ignored by
  // every other action. Returns the focused tag the edit/move was applied
  // to, or 0 if nothing is focused. Mutates the SceneGraph edit buffer (for
  // the actions that change it) and the caret (every action), then schedules
  // onSelectionChange (every action that reaches the field) and onChange
  // (only when the text actually changed) so the pixels and the JS state
  // agree.
  //
  // item 4a: `extendSelection` is Shift's effect on a caret-MOVE action
  // (MoveLeft/Right/Word*/Home/End) -- true EXTENDS the selection from the
  // current anchor (the caret moves, the anchor does not); false COLLAPSES
  // any existing selection, landing a plain Left/Right at the selection's
  // near boundary rather than one further step from the old caret (matching
  // macOS/Windows: the first plain arrow after a selection lands ON its
  // edge). Ignored by InsertChar/Backspace/DeleteForward/Submit/Newline/
  // SelectAll -- InsertChar/Backspace/DeleteForward instead consult whether
  // a selection is ALREADY active and replace/delete that range rather than
  // acting at the caret alone (a selection always collapses after an edit,
  // same as every desktop text field). Defaults to false so every existing
  // call site (the legacy Backspace/Submit/Newline path, the char handler)
  // keeps its old collapse-only behaviour with no source change.
  //
  // ⛔ ONE EDITING PATH. MoveLeft/Right/Word*/Home/End/DeleteForward/
  // SelectAll are reached ONLY from FabricHost::dispatchKeyEvent (the full
  // key path) -- see its header. Backspace/Submit/Newline stay reachable
  // ONLY from the LEGACY GlfwSurface::keyHandler_ path (main.cpp's
  // setKeyHandler), which dispatchKeyEvent's editing branch deliberately
  // does NOT re-handle, so a single physical keystroke can never mutate the
  // buffer twice.
  enum class KeyAction {
    InsertChar,
    Backspace,
    Submit,
    Newline,
    MoveLeft,
    MoveRight,
    MoveWordLeft,
    MoveWordRight,
    MoveHome,
    MoveEnd,
    DeleteForward,
    // item 4a. Anchor -> 0, caret -> end, value unchanged. Cmd+A on
    // __APPLE__, Ctrl+A elsewhere (platform dispatch is dispatchKeyEvent's
    // job, same as the word-move modifier split).
    SelectAll,
  };
  int dispatchKey(KeyAction action, unsigned int codepoint,
                  bool extendSelection = false);

  // True when a field is focused, so the windowed host knows whether to route a
  // character/key event here at all.
  bool hasTextInputFocus();
  // Non-mutating probe: is a real TextInput field under (x,y)? Used by the
  // --type harness to settle the mount before the first focus. See the .cpp.
  bool isTextInputAt(float x, float y);

  // desktop-input-gap P0 item 1. Full keyboard forwarding to JS, delivered
  // to the focused tag (falling back to the surface root when nothing is
  // focused, so the event has somewhere to land) via TWO channels:
  //   (a) if the focused tag is a TextInput, TextInputEventEmitter::onKeyPress
  //       (RN 0.86 core; KeyPressMetrics) on Down/Repeat -- NOT on Up, which
  //       onKeyPress has no concept of.
  //   (b) EventEmitter::dispatchEvent(name, payload) with a generic
  //       'keyDown'/'keyUp' event on EVERY key (focused TextInput or not),
  //       because RN 0.86's C++ BaseViewEventEmitter has no onKeyDown/onKeyUp
  //       method at all -- see docs/eng/desktop-input-gap.md. Payload shape
  //       follows react-native-windows: key, code, altKey, ctrlKey, metaKey,
  //       shiftKey (+ capsLockKey, repeat, which neither fork's payload
  //       carries but the gap doc's ask requires).
  // Returns the tag the event was delivered to (focused tag or root), or 0 if
  // nothing has mounted at all.
  struct KeyModifiers {
    bool shift{false};
    bool ctrl{false};
    bool alt{false};
    bool meta{false};
    bool capsLock{false};
  };
  enum class KeyEventPhase { Down, Repeat, Up };
  int dispatchKeyEvent(const std::string& key, const std::string& code,
                       KeyEventPhase phase, const KeyModifiers& mods);

  // The component names this host can actually mount. Handed to ReactHost so
  // RN's NativeComponentRegistry and this registry cannot drift apart.
  static std::vector<std::string> knownComponentNames();

 private:
  SceneGraph* sceneGraph_{nullptr};
  std::shared_ptr<facebook::react::RuntimeScheduler> runtimeScheduler_;
  std::shared_ptr<const facebook::react::ComponentDescriptorProviderRegistry>
      providerRegistry_;
  std::unique_ptr<facebook::react::SchedulerDelegate> delegate_;
  bool logMutations_{false};
  std::unique_ptr<facebook::react::Scheduler> scheduler_;
  std::unique_ptr<facebook::react::SurfaceHandler> surfaceHandler_;

  // ENG-09 hover/cursor. The tag the cursor is currently over, retained across
  // moves so dispatchHover can emit a leave/enter PAIR only on a transition.
  // Owned here rather than in the host because the enter/leave bookkeeping is
  // the dispatch's job, and keeping it here means the synthetic hover probe
  // and the real GLFW callback share one source of truth. Accessed only from
  // the event thread (both callers are), so it needs no lock of its own; the
  // SceneGraph reads it drives ARE locked.
  int hoveredTag_{0};

  // ENG-DRAG (P0). The tag a currently-held press captured, or 0 when no press
  // is down. Set by beginTouchCapture, read by dispatchCapturedMove/
  // endTouchCapture to route Move/Up WITHOUT re-hit-testing, cleared on release.
  // Accessed only from the event thread (all callers are), same as hoveredTag_.
  int capturedTag_{0};

  // <TextInput>. ENG-01b. Monotonic native event counter. RN's TextInput.js
  // discards a native onChange whose eventCount is <= the last it saw, to drop
  // events that raced a controlled-value round-trip. It must therefore strictly
  // increase across every event this field emits, so it lives on the host, not
  // per-dispatch.
  int tiEventCount_{0};

  // ENG-09. Emits a pointerenter or pointerleave to `tag` through its
  // TouchEventEmitter, hopping to the JS thread exactly as dispatchTouch does.
  // No-op (returns false) if the tag has no touch emitter -- an unregistered
  // or non-view node cannot receive pointer events. `x/y` are POINTS, used to
  // build the PointerEvent's coordinates.
  bool emitPointer(int tag, bool enter, float x, float y);
};

}  // namespace rni
