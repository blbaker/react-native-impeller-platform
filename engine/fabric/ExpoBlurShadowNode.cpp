#include "fabric/ExpoBlurShadowNode.h"

#include <react/renderer/core/propsConversions.h>

namespace facebook::react {

ExpoBlurViewProps::ExpoBlurViewProps(const PropsParserContext& context,
                                     const ExpoBlurViewProps& sourceProps,
                                     const RawProps& rawProps)
    : ViewProps(context, sourceProps, rawProps),
      tint(convertRawProp(context, rawProps, "tint", sourceProps.tint, {"default"})),
      intensity(convertRawProp(context, rawProps, "intensity", sourceProps.intensity, {50.0f})),
      blurReductionFactor(convertRawProp(context, rawProps, "blurReductionFactor",
                                         sourceProps.blurReductionFactor, {4.0f})) {}

}  // namespace facebook::react
