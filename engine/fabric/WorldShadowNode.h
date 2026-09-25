// ENG-09 — <world> ShadowNode + ComponentDescriptor.
//
// <world> is a plain leaf host component: it has no Fabric-owned rendering
// contract of its own (no image loading, no state machine) -- it exists so
// JS can mount a rectangle that SceneGraph's world painter fills from
// WorldRasterStore by the node's own `name` prop (see WorldRasterStore.h /
// WorldRasterModule.h for the write side; the SAME store is read here on the
// paint side, keyed by the identical string).
//
// PROPS/EVENTS ARE BORROWED FROM RNSVGImage ON PURPOSE, NOT BECAUSE <world>
// IS AN IMAGE. RNSVGImageProps already carries the one field this node
// needs -- a `name: string` prop -- plus the ordinary ViewProps every host
// component gets (layout, background, opacity, transform...), and reusing
// it means no new codegen pass, no new generated Props/EventEmitters pair,
// and no drift between what this file declares and what a real generated
// pair would look like. RNSVGImageEventEmitter is likewise just "ViewProps'
// event emitter, already generated" -- <world> emits no image-load events,
// it simply needs *an* EventEmitter type to satisfy the template, and this
// one is already linked into the binary via rnsvg_common.
//
// StateData is the LIBRARY DEFAULT (facebook::react::StateData: an empty,
// serializable placeholder), NOT RNSVGImageState -- <world> has no async
// image-loading state to track between commits, so there is nothing for a
// state object to hold. Reaching for RNSVGImageState here would be copying
// the shape of a problem <world> does not have.
#pragma once

#include <react/renderer/components/rnsvg/EventEmitters.h>
#include <react/renderer/components/rnsvg/Props.h>
#include <react/renderer/components/view/ConcreteViewShadowNode.h>
#include <react/renderer/core/ConcreteComponentDescriptor.h>
#include <react/renderer/core/StateData.h>

namespace facebook::react {

// `inline` (not `extern`) so this header can be included from multiple
// translation units with no companion .cpp: C++17 inline variables get one
// definition across the whole program, same guarantee `extern` + a .cpp
// definition would give, without the extra file. Value MUST equal the
// string RN's <world> host component resolves to (package/src/worldraster's
// native primitive is a TurboModule, not this -- this is the VIEW half:
// whatever JSX host-component name a consuming app mounts as `world`).
inline constexpr const char WorldShadowNodeComponentName[] = "world";

/*
 * `ShadowNode` for the <world> host component. A leaf, same as
 * RNSVGImageShadowNode's LeafYogaNode trait -- it paints a rectangle of
 * externally-supplied pixels and has no Yoga children of its own to lay out.
 */
class JSI_EXPORT WorldShadowNode final
    : public ConcreteViewShadowNode<WorldShadowNodeComponentName,
                                    RNSVGImageProps, RNSVGImageEventEmitter,
                                    StateData> {
 public:
  using ConcreteViewShadowNode::ConcreteViewShadowNode;

  static ShadowNodeTraits BaseTraits() {
    auto traits = ConcreteViewShadowNode::BaseTraits();
    traits.set(ShadowNodeTraits::Trait::LeafYogaNode);
    return traits;
  }
};

/*
 * Descriptor for <world>. No adopt() override, no ImageManager, no
 * contextContainer dependency -- unlike RNSVGImageComponentDescriptor this
 * node needs nothing beyond what ConcreteComponentDescriptor's own ctor
 * already wires, so a bare `using` alias (the same shape RNSVGGroup/
 * RNSVGPath/etc. use in RNSVGComponentDescriptors.h) is the whole descriptor.
 */
using WorldComponentDescriptor = ConcreteComponentDescriptor<WorldShadowNode>;

}  // namespace facebook::react
