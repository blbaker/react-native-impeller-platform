#include "fabric/FabricHost.h"

#include <react/renderer/componentregistry/ComponentDescriptorProviderRegistry.h>
#include <react/renderer/components/root/RootComponentDescriptor.h>
#include <react/renderer/components/text/ParagraphComponentDescriptor.h>
#include <react/renderer/components/text/RawTextComponentDescriptor.h>
#include <react/renderer/components/text/TextComponentDescriptor.h>
#include <react/renderer/components/view/ViewComponentDescriptor.h>
#include <react/renderer/core/EventBeat.h>
#include <react/renderer/core/LayoutConstraints.h>
#include <react/renderer/core/LayoutContext.h>
#include <react/renderer/mounting/MountingCoordinator.h>
#include <react/renderer/mounting/MountingTransaction.h>
#include <react/renderer/runtimescheduler/RuntimeScheduler.h>
#include <react/renderer/scheduler/Scheduler.h>
#include <react/renderer/scheduler/SchedulerDelegate.h>
#include <react/renderer/scheduler/SchedulerToolbox.h>
#include <react/renderer/scheduler/SurfaceHandler.h>
#include <react/runtime/ReactInstance.h>
#include <react/utils/ContextContainer.h>

#if RNI_WITH_RNSVG
// Two ComponentDescriptor headers: the vendor's own (Group/Path/... — hand-
// written `using` aliases in common/cpp/) and ours (SvgView — codegen output,
// since react-native-svg's Svg.js resolves to the platform-suffixed
// RNSVGSvgView/RNSVGSvgViewAndroid names that only the codegen emits).
// See engine/cmake/RnSvg.cmake's header comment on the vendor-owns-contract
// / we-own-pixels split.
#include "RNSVGComponentDescriptors.h"
#include <react/renderer/components/rnsvg/ComponentDescriptors.h>
#endif

#include <atomic>
#include <cstdio>

#include "modules/CoreModules.h"
#include "scenegraph/SceneGraph.h"
#include "text/ImpellerTextLayoutManager.h"

namespace rni {

namespace react = facebook::react;

namespace {

class ImpellerSchedulerDelegate : public react::SchedulerDelegate {
 public:
  ImpellerSchedulerDelegate(SceneGraph* sceneGraph, bool logMutations)
      : sceneGraph_(sceneGraph), logMutations_(logMutations) {}

  void schedulerDidFinishTransaction(
      const std::shared_ptr<const react::MountingCoordinator>&) override {
    // Android-only observation hook; we pull in ShouldRender below.
  }

  void schedulerShouldRenderTransactions(
      const std::shared_ptr<const react::MountingCoordinator>&
          mountingCoordinator) override {
    // ⛔ EXACTLY ONE PULL PER RENDER STEP. Do not turn this into a
    // `while (auto t = pullTransaction())` drain loop: once a
    // MountingOverrideDelegate is registered (RN's LayoutAnimation KFM), the
    // override branch manufactures a fresh transaction on every call while
    // shouldOverridePullTransaction() is true, so the loop never terminates
    // and the JS thread never returns to its event loop. RN's own consumer
    // pulls exactly once.
    if (auto transaction = mountingCoordinator->pullTransaction()) {
      if (sceneGraph_ != nullptr) {
        sceneGraph_->applyMutations(transaction->getMutations(), logMutations_);
      }
    }
  }

  void schedulerShouldMergeReactRevision(react::SurfaceId) override {}
  void schedulerDidRequestPreliminaryViewAllocation(
      const react::ShadowNode&) override {}
  void schedulerDidDispatchCommand(const react::ShadowView&, const std::string&,
                                   const folly::dynamic&) override {}
  void schedulerDidSendAccessibilityEvent(const react::ShadowView&,
                                          const std::string&) override {}
  void schedulerDidSetIsJSResponder(const react::ShadowView&, bool,
                                    bool) override {}
  void schedulerShouldSynchronouslyUpdateViewOnUIThread(
      react::Tag, const folly::dynamic&) override {}
  void schedulerDidUpdateShadowTree(
      const std::unordered_map<react::Tag, folly::dynamic>&) override {}
  void schedulerDidCaptureViewSnapshot(react::Tag, react::SurfaceId) override {}
  void schedulerDidSetViewSnapshot(react::Tag, react::Tag,
                                   react::SurfaceId) override {}
  void schedulerDidClearPendingSnapshots() override {}

 private:
  SceneGraph* sceneGraph_;
  bool logMutations_;
};

// ⛔ The base EventBeat is INERT: request() only sets a flag, and the PLATFORM
// is expected to call induce() before its run loop sleeps (iOS run-loop
// observer / Android Choreographer). Without a beat that actually induces,
// events dispatched through EventDispatcher queue forever and JS never sees
// one — with no error anywhere.
class ImpellerEventBeat : public react::EventBeat {
 public:
  ImpellerEventBeat(std::shared_ptr<OwnerBox> ownerBox,
                    react::RuntimeScheduler& runtimeScheduler)
      : EventBeat(std::move(ownerBox), runtimeScheduler),
        runtimeScheduler_(runtimeScheduler) {}

  void request() const override {
    EventBeat::request();
    bool expected = false;
    if (isInduceScheduled_.compare_exchange_strong(expected, true)) {
      runtimeScheduler_.scheduleWork(
          [this, ownerBox = ownerBox_](facebook::jsi::Runtime&) {
            auto owner = ownerBox->owner.lock();
            if (!owner) return;
            isInduceScheduled_ = false;
            induce();
          });
    }
  }

 private:
  react::RuntimeScheduler& runtimeScheduler_;
  mutable std::atomic<bool> isInduceScheduled_{false};
};

}  // namespace

std::vector<std::string> FabricHost::knownComponentNames() {
  // MUST match the provider registry below. A component in one list and not
  // the other fails in a way that looks exactly like "the engine does not
  // have it": RN takes a fallback path, nothing mounts, nothing logs.
  std::vector<std::string> names = {"View", "RootView", "Paragraph", "Text",
                                     "RawText"};
#if RNI_WITH_RNSVG
  names.insert(names.end(), {"RNSVGSvgView", "RNSVGGroup", "RNSVGPath",
                             "RNSVGRect", "RNSVGCircle", "RNSVGEllipse",
                             "RNSVGLine"});
#endif
  return names;
}

FabricHost::FabricHost(react::ReactInstance& instance, SceneGraph* sceneGraph,
                       ImpellerTypographyContext typography, bool logMutations,
                       std::shared_ptr<DisplayMetrics> displayMetrics) {
  runtimeScheduler_ = instance.getRuntimeScheduler();
  sceneGraph_ = sceneGraph;
  logMutations_ = logMutations;

  auto providerRegistry =
      std::make_shared<const react::ComponentDescriptorProviderRegistry>();
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RootComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ViewComponentDescriptor>());
  // <Text>: Paragraph is the measurable leaf; Text/RawText are virtual.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ParagraphComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::TextComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RawTextComponentDescriptor>());
#if RNI_WITH_RNSVG
  // RNSVGSvgView's ComponentDescriptor is OUR codegen output (react-native-svg's
  // Svg.js resolves to the platform-suffixed name, which only the codegen
  // emits); Group/Path use the vendor's own hand-written `using` aliases.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGSvgViewComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGGroupComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGPathComponentDescriptor>());
  // The basic shapes. Each is converted to path data in SceneGraph and painted
  // by the SAME fill/stroke code as <Path>, so registering them costs a line
  // here and nothing in the painter.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGRectComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGCircleComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGEllipseComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGLineComponentDescriptor>());
#endif
  providerRegistry_ = providerRegistry;

  auto contextContainer = std::make_shared<react::ContextContainer>();
  contextContainer->insert("DisplayMetrics", std::move(displayMetrics));
  // ⛔ MUST be inserted as the BASE-type shared_ptr. ParagraphComponentDescriptor
  // looks this up with getManagerByName<TextLayoutManager>, which does a
  // find<std::shared_ptr<TextLayoutManager>> — insert the derived type and the
  // lookup MISSES SILENTLY, RN news the platform/cxx stub instead, and every
  // <Text> measures 0x0 while the log stays clean.
  contextContainer->insert(
      "TextLayoutManager",
      std::shared_ptr<react::TextLayoutManager>(
          std::make_shared<ImpellerTextLayoutManager>(contextContainer, typography)));
  // Scheduler's ctor asserts on this key. Weak ptr, same shape as RCTInstance.
  contextContainer->insert(
      react::RuntimeSchedulerKey,
      std::weak_ptr<react::RuntimeScheduler>(runtimeScheduler_));

  react::SchedulerToolbox toolbox;
  toolbox.contextContainer = contextContainer;
  toolbox.componentRegistryFactory =
      [providerRegistry](const react::EventDispatcher::Weak& eventDispatcher,
                         const std::shared_ptr<const react::ContextContainer>& cc)
      -> react::SharedComponentDescriptorRegistry {
    return providerRegistry->createComponentDescriptorRegistry(
        {eventDispatcher, cc, nullptr});
  };
  // UNBUFFERED for the bindings executor: UIManagerBinding must be installed
  // BEFORE the main bundle evaluates, because ReactFabric grabs
  // global.nativeFabricUIManager at init. The buffered executor would queue it
  // behind the bundle and JS would find it missing.
  toolbox.bridgelessBindingsExecutor =
      std::optional<react::RuntimeExecutor>(instance.getUnbufferedRuntimeExecutor());
  toolbox.runtimeExecutor = instance.getBufferedRuntimeExecutor();
  toolbox.eventBeatFactory =
      [runtimeScheduler = runtimeScheduler_](
          std::shared_ptr<react::EventBeat::OwnerBox> ownerBox)
      -> std::unique_ptr<react::EventBeat> {
    return std::make_unique<ImpellerEventBeat>(std::move(ownerBox),
                                               *runtimeScheduler);
  };

  delegate_ = std::make_unique<ImpellerSchedulerDelegate>(sceneGraph, logMutations);
  scheduler_ = std::make_unique<react::Scheduler>(
      toolbox, /*animationDelegate*/ nullptr, delegate_.get());
  std::printf("[fabric] scheduler up (UIManagerBinding installed)\n");
  std::fflush(stdout);
}

FabricHost::~FabricHost() {
  stopSurface();
  // In-flight rendering-update lambdas captured a raw delegate pointer, and
  // the Scheduler only invalidates them behind a feature flag — drop the
  // delegate reference explicitly before tearing down.
  if (scheduler_) {
    scheduler_->setDelegate(nullptr);
  }
  scheduler_.reset();
  delegate_.reset();
}

void FabricHost::startSurface(const std::string& moduleName, int surfaceId,
                              float width, float height, float pointScaleFactor) {
  surfaceHandler_ = std::make_unique<react::SurfaceHandler>(
      moduleName, static_cast<react::SurfaceId>(surfaceId));
  scheduler_->registerSurface(*surfaceHandler_);

  // ⛔ WIDTH/HEIGHT ARRIVE IN DEVICE PIXELS; YOGA LAYS OUT IN POINTS.
  // React Native's unit is the POINT, and pointScaleFactor is how many device
  // pixels one point occupies. A 800x600 @2x surface is 400x300 POINTS, and a
  // `width: 200` view must occupy 200 points = 400 device pixels.
  //
  // Constraining Yoga with raw pixels while claiming scale 2 would lay out an
  // 800-point-wide tree and then rasterise it twice as large again — content
  // scaled to 4x, clipped on every side. Divide once, here, where the pixel
  // count enters the layout system.
  const float scale = pointScaleFactor > 0.0f ? pointScaleFactor : 1.0f;
  const float pointWidth = width / scale;
  const float pointHeight = height / scale;

  react::LayoutConstraints constraints;
  constraints.minimumSize = {.width = pointWidth, .height = pointHeight};
  constraints.maximumSize = {.width = pointWidth, .height = pointHeight};
  constraints.layoutDirection = react::LayoutDirection::LeftToRight;
  react::LayoutContext layoutContext;
  // Fabric rounds every layout value to a whole device pixel using this. Left
  // at 1.0 on a 2x display, a 0.5-point border rounds to 0 and vanishes rather
  // than becoming the 1 physical pixel it should be.
  layoutContext.pointScaleFactor = scale;
  surfaceHandler_->constraintLayout(constraints, layoutContext);

  surfaceHandler_->start();  // → AppRegistry.runApplication on the JS thread

  std::printf("[fabric] surface %d (%s) started %gx%g points @%gx (%gx%g px)\n",
              surfaceId, moduleName.c_str(), (double)pointWidth,
              (double)pointHeight, (double)scale, (double)width,
              (double)height);
  std::fflush(stdout);
}

void FabricHost::stopSurface() {
  if (!surfaceHandler_) return;
  if (surfaceHandler_->getStatus() == react::SurfaceHandler::Status::Running) {
    surfaceHandler_->stop();
  }
  scheduler_->unregisterSurface(*surfaceHandler_);
  surfaceHandler_.reset();
}

}  // namespace rni
