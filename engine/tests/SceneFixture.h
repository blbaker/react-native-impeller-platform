#pragma once
// FP-50: canned Fabric mutation lists for SceneGraph, built through the real component
// descriptors (fuzz/FuzzFabric) so props parse exactly as a React commit's would. No GPU, no JS.
#include <folly/dynamic.h>
#include <react/renderer/core/ComponentDescriptor.h>
#include <react/renderer/mounting/ShadowView.h>
#include <react/renderer/mounting/ShadowViewMutation.h>

#include <map>
#include <memory>
#include <string>

#include "scenegraph/SceneGraph.h"

namespace rni::test {

using Tag = facebook::react::Tag;

struct TextStyle {
  float fontSize{14};
  std::string family;
  uint32_t argb{0xFF000000};
};

class TestScene {
 public:
  explicit TestScene(float width = 200, float height = 200);

  // Parent 1 is the root. propsJson is the object JS would pass to createNode (colours as ARGB ints).
  Tag Add(const char* component, Tag parent, const std::string& propsJson, float x, float y, float w, float h);
  Tag View(Tag parent, const std::string& propsJson, float x, float y, float w, float h) {
    return Add("View", parent, propsJson, x, y, w, h);
  }
  Tag Text(Tag parent, const std::string& text, float x, float y, float w, float h,
           const TextStyle& style = {}, const std::string& propsJson = "{}");
  void Update(Tag tag, const std::string& propsJson);
  void Remove(Tag tag);

  // Commits pending mutations, paints once into a display list builder with a Capture
  // installed, and returns the op log (withState adds " | ctm=... clip=..." to draw/clip ops).
  std::string Ops(bool withState = false, float pointScale = 1.0f);
  SceneGraph& scene() { return *scene_; }

 private:
  struct Node {
    const facebook::react::ComponentDescriptor* desc;
    facebook::react::ShadowView view;
    Tag parent{0};
    int children{0};
  };
  const facebook::react::ComponentDescriptor& Descriptor(const std::string& name);

  std::unique_ptr<SceneGraph> scene_;
  std::map<Tag, Node> nodes_;
  facebook::react::ShadowViewMutation::List pending_;
  Tag next_{2};
};

}  // namespace rni::test
