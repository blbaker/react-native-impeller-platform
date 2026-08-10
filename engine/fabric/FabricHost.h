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
  void startSurface(const std::string& moduleName, int surfaceId, float width,
                    float height);
  void stopSurface();

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
