// FP-42 <ImpellerTextureView textureId={id}>: a leaf view that paints an
// external texture (TextureRegistry). Flutter's Texture widget -> TextureLayer
// (flow/layers/texture_layer.cc); the RN shape is a host component with one
// prop. Props are hand-written (ViewProps + textureId) the way RN's own
// ImageProps parse theirs, so no codegen pass is needed.
#pragma once

#include <react/featureflags/ReactNativeFeatureFlags.h>
#include <react/renderer/components/view/ConcreteViewShadowNode.h>
#include <react/renderer/components/view/ViewEventEmitter.h>
#include <react/renderer/components/view/ViewProps.h>
#include <react/renderer/core/ConcreteComponentDescriptor.h>
#include <react/renderer/core/PropsMacros.h>
#include <react/renderer/core/propsConversions.h>

#include <cstdint>

namespace facebook::react {

// Must equal the JS uiViewClassName.
inline constexpr const char ImpellerTextureViewComponentName[] = "ImpellerTextureView";

class ImpellerTextureViewProps final : public ViewProps {
 public:
  ImpellerTextureViewProps() = default;
  ImpellerTextureViewProps(const PropsParserContext& context,
                           const ImpellerTextureViewProps& sourceProps, const RawProps& rawProps)
      : ViewProps(context, sourceProps, rawProps),
        textureId(ReactNativeFeatureFlags::enableCppPropsIteratorSetter()
                      ? sourceProps.textureId
                      : convertRawProp(context, rawProps, "textureId", sourceProps.textureId,
                                       (int64_t)0)) {}

  void setProp(const PropsParserContext& context, RawPropsPropNameHash hash,
               const char* propName, const RawValue& value) {
    ViewProps::setProp(context, hash, propName, value);
    static auto defaults = ImpellerTextureViewProps{};
    switch (hash) {
      RAW_SET_PROP_SWITCH_CASE_BASIC(textureId);
    }
  }

  int64_t textureId{0};
};

class JSI_EXPORT ImpellerTextureViewShadowNode final
    : public ConcreteViewShadowNode<ImpellerTextureViewComponentName, ImpellerTextureViewProps,
                                    ViewEventEmitter> {
 public:
  using ConcreteViewShadowNode::ConcreteViewShadowNode;

  static ShadowNodeTraits BaseTraits() {
    auto traits = ConcreteViewShadowNode::BaseTraits();
    traits.set(ShadowNodeTraits::Trait::LeafYogaNode);
    return traits;
  }
};

using ImpellerTextureViewComponentDescriptor =
    ConcreteComponentDescriptor<ImpellerTextureViewShadowNode>;

}  // namespace facebook::react
