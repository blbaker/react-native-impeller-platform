// FP-50: see SceneFixture.h.
#include "tests/SceneFixture.h"

#include <folly/json.h>
#include <react/renderer/components/text/ParagraphProps.h>
#include <react/renderer/components/text/ParagraphState.h>
#include <react/renderer/core/ConcreteState.h>
#include <react/renderer/graphics/Color.h>

#include <cstdio>
#include <cstdlib>

#include "fuzz/FuzzFabric.h"
#include "scenegraph/DrawOpLog.h"

namespace rni::test {

namespace react = facebook::react;

namespace {

folly::dynamic Parse(const std::string& json) {
  try {
    return folly::parseJson(json);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "fixture: bad props json '%s': %s\n", json.c_str(), e.what());
    std::abort();
  }
}

react::Props::Shared PropsOrDie(const react::ComponentDescriptor& desc, const react::Props::Shared& base,
                                const std::string& json) {
  auto props = fuzz::MakePropsExact(desc, base, Parse(json));
  if (!props) {
    std::fprintf(stderr, "fixture: %s rejected props %s\n", desc.getComponentName(), json.c_str());
    std::abort();
  }
  return props;
}

}  // namespace

TestScene::TestScene(float width, float height) : scene_(fuzz::NewScene()) {
  const react::ComponentDescriptor& root = fuzz::RootComponent();
  Node n{&root, fuzz::MakeView(root, 1, PropsOrDie(root, nullptr, "{}"), 0, 0, width, height), 0, 0};
  nodes_[1] = n;
  pending_.push_back(react::ShadowViewMutation::UpdateMutation(n.view, n.view, 0));
}

const react::ComponentDescriptor& TestScene::Descriptor(const std::string& name) {
  for (const auto* d : fuzz::Components()) {
    if (name == d->getComponentName()) return *d;
  }
  std::fprintf(stderr, "fixture: no component %s (RNSVG ones need RNI_WITH_RNSVG)\n", name.c_str());
  std::abort();
}

Tag TestScene::Add(const char* component, Tag parent, const std::string& propsJson, float x, float y, float w,
                   float h) {
  const react::ComponentDescriptor& desc = Descriptor(component);
  const Tag tag = next_++;
  Node n{&desc, fuzz::MakeView(desc, tag, PropsOrDie(desc, nullptr, propsJson), x, y, w, h), parent, 0};
  pending_.push_back(react::ShadowViewMutation::CreateMutation(n.view));
  pending_.push_back(react::ShadowViewMutation::InsertMutation(parent, n.view, nodes_[parent].children++));
  nodes_[tag] = n;
  return tag;
}

Tag TestScene::Text(Tag parent, const std::string& text, float x, float y, float w, float h,
                    const TextStyle& style, const std::string& propsJson) {
  const react::ComponentDescriptor& desc = Descriptor("Paragraph");
  const Tag tag = next_++;
  Node n{&desc, fuzz::MakeView(desc, tag, PropsOrDie(desc, nullptr, propsJson), x, y, w, h), parent, 0};

  react::AttributedString::Fragment fragment;
  fragment.string = text;
  fragment.textAttributes.fontSize = style.fontSize;
  fragment.textAttributes.fontFamily = style.family;
  fragment.textAttributes.foregroundColor = react::colorFromRGBA(
      (style.argb >> 16) & 0xFF, (style.argb >> 8) & 0xFF, style.argb & 0xFF, style.argb >> 24);
  react::AttributedString attributed;
  attributed.appendFragment(std::move(fragment));
  n.view.state = std::make_shared<react::ConcreteState<react::ParagraphState>>(
      std::make_shared<const react::ParagraphState>(
          react::ParagraphState{std::move(attributed), react::ParagraphAttributes{}, {}}),
      react::ShadowNodeFamily::Weak{});

  pending_.push_back(react::ShadowViewMutation::CreateMutation(n.view));
  pending_.push_back(react::ShadowViewMutation::InsertMutation(parent, n.view, nodes_[parent].children++));
  nodes_[tag] = n;
  return tag;
}

void TestScene::Update(Tag tag, const std::string& propsJson) {
  Node& n = nodes_.at(tag);
  react::ShadowView next = n.view;
  next.props = PropsOrDie(*n.desc, n.view.props, propsJson);
  pending_.push_back(react::ShadowViewMutation::UpdateMutation(n.view, next, n.parent));
  n.view = next;
}

void TestScene::Remove(Tag tag) {
  Node& n = nodes_.at(tag);
  Node& parent = nodes_.at(n.parent);
  pending_.push_back(react::ShadowViewMutation::RemoveMutation(n.parent, n.view, 0));
  pending_.push_back(react::ShadowViewMutation::DeleteMutation(n.view));
  --parent.children;
  nodes_.erase(tag);
}

std::string TestScene::Ops(bool withState, float pointScale) {
  scene_->applyMutations(pending_);
  pending_.clear();
  ImpellerDisplayListBuilder builder = ImpellerDisplayListBuilderNew(nullptr);
  drawop::Capture capture;
  {
    drawop::ScopedCapture scope(capture);
    scene_->paint(builder, pointScale);
  }
  ImpellerDisplayList list = ImpellerDisplayListBuilderCreateDisplayListNew(builder);
  if (list) ImpellerDisplayListRelease(list);
  ImpellerDisplayListBuilderRelease(builder);
  return capture.Format(withState);
}

}  // namespace rni::test
