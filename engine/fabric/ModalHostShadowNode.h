// Style-coverage A22 / parity item 26: <Modal> host component. RN's Modal.js
// renders ModalHostView (codegen props: visible, transparent, animationType,
// ...) around a full-size container View. The node is a layout root sized to
// the window, like RN's own ModalHostViewComponentDescriptor, but the size
// comes from the surface the host started (RN's cxx state reports 0x0).
// SceneGraph paints and hit-tests it after the app root, at window (0,0).
#pragma once

#include <atomic>

#include <react/renderer/components/FBReactNativeSpec/EventEmitters.h>
#include <react/renderer/components/FBReactNativeSpec/Props.h>
#include <react/renderer/components/view/ConcreteViewShadowNode.h>
#include <react/renderer/components/view/YogaLayoutableShadowNode.h>
#include <react/renderer/core/ConcreteComponentDescriptor.h>

namespace rni::modal {
// Window size in points, set by FabricHost::startSurface / updateSurface.
inline std::atomic<float> gScreenW{0.0f};
inline std::atomic<float> gScreenH{0.0f};
inline void SetScreenSize(float w, float h) {
  gScreenW.store(w, std::memory_order_relaxed);
  gScreenH.store(h, std::memory_order_relaxed);
}
}  // namespace rni::modal

namespace facebook::react {

// Must equal RCTModalHostViewNativeComponent's fabric name.
inline constexpr const char ImpellerModalHostViewName[] = "ModalHostView";

class ImpellerModalHostShadowNode final
    : public ConcreteViewShadowNode<ImpellerModalHostViewName, ModalHostViewProps,
                                    ModalHostViewEventEmitter> {
 public:
  using ConcreteViewShadowNode::ConcreteViewShadowNode;
  static ShadowNodeTraits BaseTraits() {
    auto traits = ConcreteViewShadowNode::BaseTraits();
    traits.set(ShadowNodeTraits::Trait::RootNodeKind);
    traits.set(ShadowNodeTraits::Trait::Unstable_uncullableView);
    return traits;
  }
};

class ImpellerModalHostComponentDescriptor final
    : public ConcreteComponentDescriptor<ImpellerModalHostShadowNode> {
 public:
  using ConcreteComponentDescriptor::ConcreteComponentDescriptor;
  void adopt(ShadowNode& shadowNode) const override {
    auto& node = static_cast<YogaLayoutableShadowNode&>(shadowNode);
    node.setSize(Size{.width = rni::modal::gScreenW.load(std::memory_order_relaxed),
                      .height = rni::modal::gScreenH.load(std::memory_order_relaxed)});
    node.setPositionType(YGPositionTypeAbsolute);
    ConcreteComponentDescriptor::adopt(shadowNode);
  }
};

}  // namespace facebook::react
