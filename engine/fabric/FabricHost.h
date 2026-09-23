// FabricHost — the live Fabric renderer wired to a bridgeless ReactInstance:
// component descriptor registry, Scheduler built from a SchedulerToolbox, and a
// SurfaceHandler. The SchedulerDelegate (in the .cpp) pulls MountingTransactions
// on the JS thread and applies them to the retained SceneGraph.
#pragma once

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

  // ENG-09. Emits a pointerenter or pointerleave to `tag` through its
  // TouchEventEmitter, hopping to the JS thread exactly as dispatchTouch does.
  // No-op (returns false) if the tag has no touch emitter -- an unregistered
  // or non-view node cannot receive pointer events. `x/y` are POINTS, used to
  // build the PointerEvent's coordinates.
  bool emitPointer(int tag, bool enter, float x, float y);
};

}  // namespace rni
