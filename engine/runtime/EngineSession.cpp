#include "runtime/EngineSession.h"

#include <utility>

namespace rni {

EngineSession::EngineSession(ImpellerTypographyContext typography,
                             GpuBackend gpuBackend, GpuBackend gpuPolicy)
    : typography_(typography) {
  // FP-20: context/policy before anything touches the backend. The caller
  // runs setRenderContext/printGpuBackend (and, windowed only, the prewarm
  // tour) between this constructor and Boot() -- see this class's header.
  sceneGraph_ = std::make_unique<SceneGraph>(typography);
  sceneGraph_->setGpuBackend(gpuBackend, gpuPolicy);
}

EngineSession::~EngineSession() = default;

void EngineSession::Boot(int pxWidth, int pxHeight, float pointScale,
                         Options options) {
  sceneGraph_->setSupersample(options.supersampleRnsvg);
  // ENG item 2b: the root-supersample offscreen is sized N x this.
  sceneGraph_->setSurfaceSize(pxWidth, pxHeight);

  // parity item 24: a Metro-served bundle is debuggable.
  reactHost_ = std::make_unique<ReactHost>(options.withInspector);
  reactHost_->setKnownComponents(FabricHost::knownComponentNames());

  // ENG-09/FP-42/FP-43: the SAME stores the TurboModules write into.
  sceneGraph_->setWorldRasterStore(reactHost_->worldRasterStore());
  sceneGraph_->setTextureRegistry(reactHost_->textureRegistry());
  sceneGraph_->setSnapshotController(reactHost_->snapshots());
  sceneGraph_->setPlatformViewsEmbedded(options.platformViewsEmbedded);

  // Seed platform-module state BEFORE the bundle evaluates (Appearance.js
  // reads this at module scope).
  reactHost_->displayMetrics()->set((float)pxWidth / pointScale,
                                    (float)pxHeight / pointScale, pointScale);
  reactHost_->appearance()->set(options.colorScheme);
  *reactHost_->initialUrl() = options.initialUrl;

  // THE FABRIC MUST BE UP BEFORE THE BUNDLE EVALUATES.
  // The Scheduler installs UIManagerBinding through the unbuffered executor,
  // and ReactFabric reads global.nativeFabricUIManager the moment it
  // initialises -- so RunScript (called after Boot returns) must never run
  // before fabricHost_ exists. This is the order
  // tools/mutation-verify-enginesession.sh reorders to prove it is load-
  // bearing.
  fabricHost_ = std::make_unique<FabricHost>(
      reactHost_->instance(), sceneGraph_.get(), typography_,
      options.logMutations, reactHost_->displayMetrics());
}

void EngineSession::RunScript(std::string bundle, const std::string& sourceUrl) {
  reactHost_->runScript(std::move(bundle), sourceUrl);
}

bool EngineSession::WaitForJsQueueDrained(int timeoutMs) {
  return reactHost_->waitForJsQueueDrained(timeoutMs);
}

bool EngineSession::WaitForJsIdle(int timeoutMs) {
  return reactHost_->waitForJsIdle(timeoutMs);
}

void EngineSession::StartSurface(const std::string& appName, int pxWidth,
                                 int pxHeight, float pointScale) {
  fabricHost_->startSurface(appName, /*surfaceId=*/1, (float)pxWidth,
                            (float)pxHeight, pointScale);
}

void EngineSession::PumpNativeAnimated() { reactHost_->pumpNativeAnimated(); }

std::unique_ptr<FrameItem> EngineSession::RecordFrame(
    float pointScale, int pxWidth, int pxHeight,
    std::unique_ptr<FrameTimingsRecorder> frame, RecordExtras extras,
    bool allowPartial) {
  return rni::RecordFrame(*sceneGraph_, pointScale, pxWidth, pxHeight,
                          std::move(frame), extras, allowPartial);
}

void EngineSession::ApplyResize(int pxWidth, int pxHeight, float pointScale) {
  // ENG item 2b: the root-supersample offscreen must track the new
  // framebuffer before anything re-measures.
  sceneGraph_->setSurfaceSize(pxWidth, pxHeight);
  const float pointW = (float)pxWidth / pointScale;
  const float pointH = (float)pxHeight / pointScale;
  // Dimensions.get('window') / useWindowDimensions.
  reactHost_->displayMetrics()->set(pointW, pointH, pointScale);
  // ORDER IS set -> updateSurface -> emit, AND IT IS LOAD-BEARING. Emitting
  // first re-renders JS against the new Dimensions while Fabric still holds
  // the old layout constraint, committing one frame at a width the surface
  // does not have.
  fabricHost_->updateSurface(/*surfaceId=*/1, (float)pxWidth, (float)pxHeight,
                             pointScale);
  reactHost_->deviceEvents()->emit(
      "didUpdateDimensions",
      reactHost_->displayMetrics()->toDimensionsDynamic());
}

int EngineSession::DispatchTouch(FabricHost::TouchPhase phase, float x,
                                 float y) {
  return fabricHost_->dispatchTouch(phase, x, y);
}

int EngineSession::DispatchScroll(float x, float y, float dx, float dy) {
  return fabricHost_->dispatchScroll(x, y, dx, dy);
}

FabricHost::HoverResult EngineSession::DispatchHover(float x, float y) {
  return fabricHost_->dispatchHover(x, y);
}

int EngineSession::DispatchKey(FabricHost::KeyAction action,
                               unsigned int codepoint, bool extendSelection) {
  return fabricHost_->dispatchKey(action, codepoint, extendSelection);
}

}  // namespace rni
