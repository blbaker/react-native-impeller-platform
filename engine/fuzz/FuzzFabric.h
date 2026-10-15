#pragma once

// FP-52: what the props and scene targets share. Props are built through the
// SAME component descriptors FabricHost registers (fabric/ComponentRegistry),
// so a fuzzed prop map reaches SceneGraph exactly as a React commit's would.

#include <folly/dynamic.h>
#include <react/renderer/core/ComponentDescriptor.h>
#include <react/renderer/mounting/ShadowView.h>

#include <memory>
#include <string>
#include <vector>

namespace rni {
class SceneGraph;
}

namespace rni::fuzz {

// Every registered host component except RootView, in a fixed order.
const std::vector<const facebook::react::ComponentDescriptor*>& Components();
const facebook::react::ComponentDescriptor& RootComponent();

// cloneProps through the descriptor's own RawPropsParser, after dropping values
// RN's JS style processors could never emit (FuzzFabric.cpp AsJsEmits). Null when RN's
// conversion throws: in the engine that throw surfaces in JS as an error from
// the createNode/cloneNode host function, not as a crash.
facebook::react::Props::Shared MakeProps(const facebook::react::ComponentDescriptor& desc,
                                         const facebook::react::Props::Shared& base,
                                         const folly::dynamic& raw);

facebook::react::ShadowView MakeView(const facebook::react::ComponentDescriptor& desc,
                                     facebook::react::Tag tag,
                                     facebook::react::Props::Shared props,
                                     float x, float y, float w, float h);

// The headless record: paint the whole scene into a display list builder and
// finish the display list (no GPU). Returns paint()'s node count.
int Record(SceneGraph& scene, float pointScale);

// A SceneGraph wired like the headless host's (typography bound to this thread).
std::unique_ptr<SceneGraph> NewScene();

}  // namespace rni::fuzz
