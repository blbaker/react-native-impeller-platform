// FP-41: expo-blur's native <BlurView> (ExpoBlurView) as a Fabric host component.
//
// RN 0.86 has no backdrop-filter style (no "backdrop" anywhere in ViewProps or
// the JS style processors), so the backdrop blur RN apps actually use is
// expo-blur. Its JS renders requireNativeViewManager('ExpoBlur', 'ExpoBlurView'),
// which expo-modules-core turns into the host component name below
// (NativeViewManagerAdapter.native.tsx; no app-identifier suffix on this host).
// ExpoHost's getViewConfig answers that view's validAttributes so the props
// reach this node. Layout is the plain view's (BlurView sends absoluteFill).
#pragma once

#include <string>

#include <react/renderer/components/view/ConcreteViewShadowNode.h>
#include <react/renderer/components/view/ViewEventEmitter.h>
#include <react/renderer/components/view/ViewProps.h>
#include <react/renderer/core/ConcreteComponentDescriptor.h>

namespace facebook::react {

inline constexpr const char ExpoBlurViewComponentName[] = "ViewManagerAdapter_ExpoBlur_ExpoBlurView";

// expo-blur BlurModule props: tint (BlurTint string), intensity (0..100),
// blurReductionFactor (Android downscale; unused by a GPU blur).
class ExpoBlurViewProps final : public ViewProps {
 public:
  ExpoBlurViewProps() = default;
  ExpoBlurViewProps(const PropsParserContext& context, const ExpoBlurViewProps& sourceProps,
                    const RawProps& rawProps);

  std::string tint{"default"};
  Float intensity{50.0f};
  Float blurReductionFactor{4.0f};
};

using ExpoBlurViewShadowNode =
    ConcreteViewShadowNode<ExpoBlurViewComponentName, ExpoBlurViewProps, ViewEventEmitter>;
using ExpoBlurViewComponentDescriptor = ConcreteComponentDescriptor<ExpoBlurViewShadowNode>;

}  // namespace facebook::react
