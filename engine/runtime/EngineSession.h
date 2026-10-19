// EngineSession -- owns the OS-agnostic runtime triad every host platform
// needs (ReactHost, FabricHost, SceneGraph), their construction order and
// lifetime, and the per-frame/boot/resize/input calls every existing host
// already makes against them. Shared foundation for the Android and iOS
// hosts (see the Android/iOS platform plans' "EngineSession"/"EngineCore"
// sections): it NAMES AND MOVES the sequence engine/host/main.cpp already
// ran inline in both the windowed path (RunWindowed) and the headless path.
// It invents no new behavior.
//
// Two-phase on purpose. SceneGraph needs a GPU backend/policy before
// anything can call setRenderContext, but setRenderContext itself has to
// stay OUTSIDE this class: windowed needs it run on the raster thread
// (rasterizer.thread().PostSync(...)), headless calls it directly, and
// between setRenderContext and the rest of boot every existing host also
// runs printGpuBackend() (reads the already-set backend/supersample) and,
// windowed only, the prewarm tour -- none of which this class can see or
// needs to. So construction happens in two steps:
//   1. The constructor builds the SceneGraph and tells it the backend.
//   2. Boot() (called once the caller's own setRenderContext/
//      printGpuBackend/prewarm have run) finishes SceneGraph setup, then
//      constructs ReactHost and FabricHost in that order and wires them
//      together.
//
// What stays OUTSIDE this class, on purpose: CLI parsing, surface selection
// and construction, setRenderContext/printGpuBackend/the prewarm tour (GPU-
// thread-affine, platform-specific), and the WindowRasterizer/FrameScheduler
// pipeline vs. the headless single-threaded pipeline -- those already differ
// enough between windowed and headless that folding them in here would be
// inventing a new shared behavior, not naming an existing one.
#pragma once

#include <functional>
#include <memory>
#include <string>

#include "fabric/FabricHost.h"
#include "host/FrameItem.h"
#include "host/FrameTimings.h"
#include "runtime/ReactHost.h"
#include "scenegraph/GpuBackend.h"
#include "scenegraph/SceneGraph.h"

namespace rni {

class EngineSession {
 public:
  struct Options {
    bool withInspector = false;
    int supersampleRnsvg = 0;
    bool platformViewsEmbedded = false;
    std::string colorScheme = "light";
    std::string initialUrl;
    bool logMutations = false;
  };

  EngineSession(ImpellerTypographyContext typography, GpuBackend gpuBackend,
                GpuBackend gpuPolicy);
  ~EngineSession();
  EngineSession(const EngineSession&) = delete;
  EngineSession& operator=(const EngineSession&) = delete;

  SceneGraph& sceneGraph() { return *sceneGraph_; }

  // Finishes SceneGraph setup (supersample, surface size), then constructs
  // ReactHost and FabricHost -- in that order, because Fabric must exist
  // before the bundle evaluates (ReactFabric reads
  // global.nativeFabricUIManager the moment it initialises) -- and wires the
  // plumbing every call site already ran inline: known components, world
  // raster store, texture registry, snapshot controller, the
  // platform-views flag, display metrics, appearance, initial URL.
  // pxWidth/pxHeight/pointScale seed the surface size and display metrics;
  // ApplyResize re-derives and re-applies them later.
  void Boot(int pxWidth, int pxHeight, float pointScale, Options options);

  ReactHost& reactHost() { return *reactHost_; }
  FabricHost& fabricHost() { return *fabricHost_; }

  // Each caller keeps its own existing order and its own existing wait
  // (windowed: waitForJsQueueDrained around startSurface, because
  // waitForJsIdle counts a launch animation's timers as still-pending work;
  // headless: waitForJsIdle) -- these only name the calls, they do not merge
  // the two callers' sequences.
  void RunScript(std::string bundle, const std::string& sourceUrl);
  bool WaitForJsQueueDrained(int timeoutMs);
  bool WaitForJsIdle(int timeoutMs);
  void StartSurface(const std::string& appName, int pxWidth, int pxHeight,
                    float pointScale);

  // Per-frame.
  void PumpNativeAnimated();
  std::unique_ptr<FrameItem> RecordFrame(
      float pointScale, int pxWidth, int pxHeight,
      std::unique_ptr<FrameTimingsRecorder> frame,
      RecordExtras extras = nullptr, bool allowPartial = false);

  // Resize an already-started surface: re-derive layout metrics, re-
  // constrain Fabric, then tell JS. Order is load-bearing (set -> resize ->
  // emit); see the .cpp. The caller still derives pointScale and decides
  // whether to resize at all (DeriveWindowPointScale, consumeDirty() stay in
  // main.cpp).
  void ApplyResize(int pxWidth, int pxHeight, float pointScale);

  // Thin forwarders to FabricHost, for a host (Android/iOS) with no local
  // `fabric` reference of its own. Every desktop call site not listed here
  // keeps calling FabricHost directly through fabricHost().
  int DispatchTouch(FabricHost::TouchPhase phase, float x, float y);
  int DispatchScroll(float x, float y, float dx, float dy);
  FabricHost::HoverResult DispatchHover(float x, float y);
  int DispatchKey(FabricHost::KeyAction action, unsigned int codepoint,
                  bool extendSelection = false);

 private:
  ImpellerTypographyContext typography_;
  std::unique_ptr<SceneGraph> sceneGraph_;
  std::unique_ptr<ReactHost> reactHost_;
  std::unique_ptr<FabricHost> fabricHost_;
};

}  // namespace rni
