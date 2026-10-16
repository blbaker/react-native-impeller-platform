// FP-44 <ImpellerPlatformView color>: a leaf view whose pixels come from a
// native OS child view (X11 child window) the raster thread positions, clips
// and stacks to the RN box each frame. Flutter's PlatformViewLayer +
// ExternalViewEmbedder (flow/embedded_views.h); the RN shape is a host
// component. This first native view is a solid colour (`color`). Props are
// hand-written (ViewProps + color) like TextureViewShadowNode.h: no codegen.
#pragma once

#include <react/featureflags/ReactNativeFeatureFlags.h>
#include <react/renderer/components/view/ConcreteViewShadowNode.h>
#include <react/renderer/components/view/ViewEventEmitter.h>
#include <react/renderer/components/view/ViewProps.h>
#include <react/renderer/core/ConcreteComponentDescriptor.h>
#include <react/renderer/core/PropsMacros.h>
#include <react/renderer/core/propsConversions.h>
#include <react/renderer/graphics/Color.h>

namespace facebook::react {

// Must equal the JS uiViewClassName.
inline constexpr const char ImpellerPlatformViewComponentName[] = "ImpellerPlatformView";

class ImpellerPlatformViewProps final : public ViewProps {
 public:
  ImpellerPlatformViewProps() = default;
  ImpellerPlatformViewProps(const PropsParserContext& context,
                            const ImpellerPlatformViewProps& sourceProps,
                            const RawProps& rawProps)
      : ViewProps(context, sourceProps, rawProps),
        color(ReactNativeFeatureFlags::enableCppPropsIteratorSetter()
                  ? sourceProps.color
                  : convertRawProp(context, rawProps, "color", sourceProps.color,
                                   SharedColor{})) {}

  void setProp(const PropsParserContext& context, RawPropsPropNameHash hash,
               const char* propName, const RawValue& value) {
    ViewProps::setProp(context, hash, propName, value);
    static auto defaults = ImpellerPlatformViewProps{};
    switch (hash) {
      RAW_SET_PROP_SWITCH_CASE_BASIC(color);
    }
  }

  SharedColor color{};
};

class JSI_EXPORT ImpellerPlatformViewShadowNode final
    : public ConcreteViewShadowNode<ImpellerPlatformViewComponentName,
                                    ImpellerPlatformViewProps, ViewEventEmitter> {
 public:
  using ConcreteViewShadowNode::ConcreteViewShadowNode;

  static ShadowNodeTraits BaseTraits() {
    auto traits = ConcreteViewShadowNode::BaseTraits();
    traits.set(ShadowNodeTraits::Trait::LeafYogaNode);
    return traits;
  }
};

using ImpellerPlatformViewComponentDescriptor =
    ConcreteComponentDescriptor<ImpellerPlatformViewShadowNode>;

}  // namespace facebook::react
