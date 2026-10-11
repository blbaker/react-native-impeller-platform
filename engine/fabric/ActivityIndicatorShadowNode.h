// Style-coverage A20: <ActivityIndicator> host component. RN's JS renders
// ActivityIndicatorView (codegen props: animating, color, hidesWhenStopped,
// size) with the size already in its style (20 or 36), so the default layout
// is enough; unregistered it mounted as a plain View and painted nothing.
#pragma once

#include <react/renderer/components/FBReactNativeSpec/Props.h>
#include <react/renderer/components/view/ConcreteViewShadowNode.h>
#include <react/renderer/components/view/ViewEventEmitter.h>
#include <react/renderer/core/ConcreteComponentDescriptor.h>

namespace facebook::react {

// Must equal ActivityIndicatorViewNativeComponent's uiViewClassName.
inline constexpr const char ImpellerActivityIndicatorName[] = "ActivityIndicatorView";

using ImpellerActivityIndicatorShadowNode =
    ConcreteViewShadowNode<ImpellerActivityIndicatorName, ActivityIndicatorViewProps,
                           ViewEventEmitter>;
using ImpellerActivityIndicatorComponentDescriptor =
    ConcreteComponentDescriptor<ImpellerActivityIndicatorShadowNode>;

}  // namespace facebook::react
