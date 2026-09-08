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
};

}  // namespace rni
