// FP-52: prop maps -> descriptor props -> SceneGraph. Input: one byte picks the
// component, the rest is a JSON object (the props JS hands createNode). Covers
// RN's converters, our HostPlatformViewProps / PlatformColorParser / rnsvg
// codegen Props, SceneGraph::updateFromShadowView and the NativeAnimated
// direct-prop parser SceneGraph::updateViewProps.
#include <folly/json.h>
#include <react/renderer/mounting/ShadowViewMutation.h>

#include <exception>
#include <string>

#include "fuzz/Fuzz.h"
#include "fuzz/FuzzFabric.h"
#include "scenegraph/SceneGraph.h"

namespace rni::fuzz {

namespace react = facebook::react;

int Props(const uint8_t* data, size_t size) {
  if (size < 2 || size > 8192) return 0;
  const auto& comps = Components();
  const react::ComponentDescriptor& desc = *comps[data[0] % comps.size()];
  folly::dynamic raw;
  try {
    raw = folly::parseJson(std::string(reinterpret_cast<const char*>(data + 1), size - 1));
  } catch (const std::exception&) {
    return 0;
  }
  if (!raw.isObject()) return 0;

  auto props = MakeProps(desc, nullptr, raw);
  if (!props) return 0;
  // Same map again on top of itself: the clone path a re-render takes.
  auto again = MakeProps(desc, props, raw);
  if (!again) return 0;

  auto scene = NewScene();
  auto rootProps = MakeProps(RootComponent(), nullptr, folly::dynamic::object());
  auto root = MakeView(RootComponent(), 1, rootProps, 0, 0, 400, 400);
  auto node = MakeView(desc, 2, props, 10, 10, 120, 80);
  auto node2 = MakeView(desc, 2, again, 10, 10, 120, 80);
  scene->applyMutations({react::ShadowViewMutation::UpdateMutation(root, root, 0),
                         react::ShadowViewMutation::CreateMutation(node),
                         react::ShadowViewMutation::InsertMutation(1, node, 0)});
  Record(*scene, 1.0f);
  scene->applyMutations({react::ShadowViewMutation::UpdateMutation(node, node2, 1)});
  scene->updateViewProps(2, raw);
  Record(*scene, 2.0f);
  return 0;
}

}  // namespace rni::fuzz
