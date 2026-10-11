// Style audit P1 item 17 (ENG-15): <Switch> host component.
//
// RN's JS <Switch> renders its iOS arm on impeller (Platform.OS is not
// 'android'): SwitchNativeComponent, uiViewClassName "Switch", props
// value/disabled/onTintColor/tintColor/thumbTintColor, and an onChange
// {value, target} event. Props + emitter are RN's own generated pair
// (FBReactNativeSpec Props.h / EventEmitters.h), compiled in by
// cmake/ReactCommonFabric.cmake.
//
// The ShadowNode is OURS, not RN's AppleSwitchShadowNode: RN's measures
// through UIKit/AppKit (IOSSwitchShadowNode.mm / MacOSSwitchShadowNode.mm,
// [UISwitch new].intrinsicContentSize). We return the iOS UISwitch intrinsic
// size, 51 x 31 pt, which every RN iOS layout that holds a Switch was built
// against. Unregistered, <Switch> mounted as a plain View that measured
// 0 x 0 and painted nothing (audit tile 62).
#pragma once

#include <react/renderer/components/FBReactNativeSpec/EventEmitters.h>
#include <react/renderer/components/FBReactNativeSpec/Props.h>
#include <react/renderer/components/view/ConcreteViewShadowNode.h>
#include <react/renderer/core/ConcreteComponentDescriptor.h>
#include <react/renderer/core/LayoutConstraints.h>
#include <react/renderer/core/LayoutContext.h>

namespace facebook::react {

// Must equal SwitchNativeComponent's uiViewClassName.
inline constexpr const char ImpellerSwitchComponentName[] = "Switch";

// iOS UISwitch intrinsicContentSize (points). Also what SceneGraph paints in.
inline constexpr float kSwitchWidth = 51.0f;
inline constexpr float kSwitchHeight = 31.0f;

class JSI_EXPORT ImpellerSwitchShadowNode final
    : public ConcreteViewShadowNode<ImpellerSwitchComponentName, SwitchProps,
                                    SwitchEventEmitter> {
 public:
  using ConcreteViewShadowNode::ConcreteViewShadowNode;

  static ShadowNodeTraits BaseTraits() {
    auto traits = ConcreteViewShadowNode::BaseTraits();
    traits.set(ShadowNodeTraits::Trait::LeafYogaNode);
    traits.set(ShadowNodeTraits::Trait::MeasurableYogaNode);
    return traits;
  }

  Size measureContent(const LayoutContext& /*layoutContext*/,
                      const LayoutConstraints& /*layoutConstraints*/) const override {
    return {kSwitchWidth, kSwitchHeight};
  }
};

using ImpellerSwitchComponentDescriptor =
    ConcreteComponentDescriptor<ImpellerSwitchShadowNode>;

}  // namespace facebook::react
