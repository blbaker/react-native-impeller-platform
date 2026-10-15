// FP-52: random mutation lists applied to SceneGraph, each commit followed by a
// headless record. The generator keeps Fabric's own invariants (a tree: create
// before insert, insert only a detached node outside the parent's ancestry,
// remove at the real index, delete only detached leaves, the root arrives as an
// Update), so a finding is a painter defect and not an impossible transaction.
// Model: Skia fuzz/FuzzCanvas.cpp (a FuzzedDataProvider drives API calls).
#include <fuzzer/FuzzedDataProvider.h>
#include <folly/json.h>
#include <react/renderer/mounting/ShadowViewMutation.h>

#include <algorithm>
#include <map>
#include <string>
#include <vector>

#include "fuzz/Fuzz.h"
#include "fuzz/FuzzFabric.h"
#include "scenegraph/SceneGraph.h"

namespace rni::fuzz {

namespace react = facebook::react;

namespace {

// Flattened style + component props Fabric hands createNode (what RN's
// processors emit: colors are already ints, transforms are op lists).
constexpr const char* kKeys[] = {
    "backgroundColor", "opacity", "transform", "width", "height", "borderRadius",
    "borderWidth", "borderColor", "borderStyle", "borderTopLeftRadius", "borderCurve",
    "overflow", "display", "zIndex", "boxShadow", "filter", "mixBlendMode", "outlineWidth",
    "outlineColor", "outlineOffset", "outlineStyle", "shadowColor", "shadowOpacity",
    "shadowRadius", "shadowOffset", "experimental_backgroundImage", "backfaceVisibility",
    "pointerEvents", "hitSlop", "transformOrigin", "isolation", "source", "sources",
    "resizeMode", "tintColor", "blurRadius", "capInsets", "value", "on", "disabled",
    "trackColorForTrue", "thumbTintColor", "animating", "color", "size", "visible",
    "transparent", "placeholder", "selection", "editable", "multiline", "fontSize",
    "contentOffset", "horizontal", "showsVerticalScrollIndicator", "d", "fill",
    "fillOpacity", "fillRule", "stroke", "strokeWidth", "strokeDasharray",
    "strokeDashoffset", "strokeLinecap", "strokeLinejoin", "strokeMiterlimit", "matrix",
    "x", "y", "x1", "y1", "x2", "y2", "r", "rx", "ry", "cx", "cy", "minX", "minY",
    "vbWidth", "vbHeight", "align", "meetOrSlice", "bbWidth", "bbHeight", "href", "name",
    "gradient", "gradientUnits", "gradientTransform", "fx", "fy", "propList", "clipPath",
    "mask", "markerStart", "nativeID", "testID",
};

// Values a generator rarely assembles by chance (shapes RN actually sends).
constexpr const char* kCanned[] = {
    R"([{"rotate":"45deg"},{"scale":2}])", R"([{"translateX":10},{"skewX":"10deg"}])",
    R"([{"matrix":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}])", R"([{"perspective":0}])",
    R"({"width":2,"height":-3})", R"([{"uri":"file:///nonexistent/fuzz.png","width":4,"height":4}])",
    R"([{"offsetX":2,"offsetY":3,"blurRadius":4,"spreadDistance":-1,"color":4278190335,"inset":true}])",
    R"([{"blur":3},{"brightness":0.5},{"hue-rotate":90},{"drop-shadow":{"offsetX":1,"offsetY":1,"standardDeviation":2,"color":4278190080}}])",
    R"({"type":0,"payload":4278190335})", R"({"type":1,"brushRef":"g1"})", R"({"type":2})",
    R"([0,0,1,0,0,1])", R"([5,3,2])", R"([0,0])", R"([1e30,-1,0.5])", R"(["50%",3])",
    R"([0,4278190335,1,4294901760])", R"([0.1,0.2,0.3,0.4])", R"("M0 0L10 10Z")",
    R"("M10 10A5 5 0 1 1 20 20C1 2 3 4 5 6S7 8 9 10Q1 1 2 2T5 5Z")", R"("50%")", R"("auto")",
    R"("#ff000080")", R"J("url(#g1)")J", R"({"top":5,"left":-5})",
    R"([{"type":"linear-gradient","direction":{"type":"angle","value":45},"colorStops":[{"color":4278190335},{"color":4294901760}]}])",
};

folly::dynamic GenValue(FuzzedDataProvider& in, int depth);

folly::dynamic GenObject(FuzzedDataProvider& in, int depth) {
  folly::dynamic o = folly::dynamic::object();
  const int n = in.ConsumeIntegralInRange(0, 6);
  for (int i = 0; i < n && in.remaining_bytes() > 0; ++i) {
    o[in.PickValueInArray(kKeys)] = GenValue(in, depth - 1);
  }
  return o;
}

folly::dynamic GenValue(FuzzedDataProvider& in, int depth) {
  switch (in.ConsumeIntegralInRange(0, depth > 0 ? 9 : 6)) {
    case 0: return nullptr;
    case 1: return in.ConsumeBool();
    case 2: return in.ConsumeIntegralInRange<int64_t>(-1000, 1000);
    case 3: return in.ConsumeIntegral<int64_t>();
    case 4: return in.ConsumeFloatingPoint<double>();  // NaN/inf included: JSI can send them
    case 5: return in.ConsumeRandomLengthString(32);
    case 6: return folly::parseJson(in.PickValueInArray(kCanned));
    case 7: {
      folly::dynamic a = folly::dynamic::array();
      const int n = in.ConsumeIntegralInRange(0, 6);
      for (int i = 0; i < n; ++i) a.push_back(GenValue(in, depth - 1));
      return a;
    }
    default: return GenObject(in, depth);
  }
}

struct Node {
  const react::ComponentDescriptor* desc;
  react::ShadowView view;
  react::Tag parent{0};  // 0 = detached
  std::vector<react::Tag> kids;
};

class Model {
 public:
  explicit Model(FuzzedDataProvider& in) : in_(in) {
    auto props = MakeProps(RootComponent(), nullptr, folly::dynamic::object());
    nodes_[1] = {&RootComponent(), MakeView(RootComponent(), 1, props, 0, 0, 800, 600), 0, {}};
    list_.push_back(react::ShadowViewMutation::UpdateMutation(nodes_[1].view, nodes_[1].view, 0));
  }

  void Step(SceneGraph& scene) {
    switch (in_.ConsumeIntegralInRange(0, 7)) {
      case 0: Create(); break;
      case 1: Insert(); break;
      case 2: Remove(); break;
      case 3: Delete(); break;
      case 4: Update(); break;
      case 5: scene.updateViewProps(PickTag(true), GenObject(in_, 2)); break;
      case 6:
        scene.scrollBy(in_.ConsumeFloatingPointInRange<float>(-50, 900),
                       in_.ConsumeFloatingPointInRange<float>(-50, 700),
                       in_.ConsumeFloatingPointInRange<float>(-5000, 5000),  // wheel deltas
                       in_.ConsumeFloatingPointInRange<float>(-5000, 5000));
        break;
      default: Commit(scene); break;
    }
  }

  void Commit(SceneGraph& scene) {
    scene.applyMutations(list_);
    list_.clear();
    Record(scene, in_.ConsumeBool() ? 1.0f : 2.0f);
  }

 private:
  react::ShadowView View(const react::ComponentDescriptor& d, react::Tag tag,
                         react::Props::Shared props) {
    const float x = in_.ConsumeFloatingPointInRange<float>(-1000, 2000);
    const float y = in_.ConsumeFloatingPointInRange<float>(-1000, 2000);
    const float w = in_.ConsumeFloatingPointInRange<float>(0, 2000);
    const float h = in_.ConsumeFloatingPointInRange<float>(0, 2000);
    return MakeView(d, tag, std::move(props), x, y, w, h);
  }

  // Any live tag (or, when `any`, sometimes one that never existed).
  react::Tag PickTag(bool any) {
    if (any && in_.ConsumeIntegralInRange(0, 7) == 0) return in_.ConsumeIntegral<int32_t>();
    auto it = nodes_.begin();
    std::advance(it, in_.ConsumeIntegralInRange<size_t>(0, nodes_.size() - 1));
    return it->first;
  }

  bool IsAncestorOrSelf(react::Tag maybe, react::Tag of) {
    for (react::Tag t = of; t != 0; t = nodes_[t].parent) {
      if (t == maybe) return true;
    }
    return false;
  }

  void Create() {
    if (nodes_.size() >= 48) return;
    const auto& comps = Components();
    const auto* d = comps[in_.ConsumeIntegralInRange<size_t>(0, comps.size() - 1)];
    auto props = MakeProps(*d, nullptr, GenObject(in_, 3));
    if (!props) return;
    const react::Tag tag = next_++;
    nodes_[tag] = {d, View(*d, tag, props), 0, {}};
    list_.push_back(react::ShadowViewMutation::CreateMutation(nodes_[tag].view));
  }

  void Insert() {
    const react::Tag child = PickTag(false), parent = PickTag(false);
    if (child == 1 || nodes_[child].parent != 0 || IsAncestorOrSelf(child, parent)) return;
    auto& kids = nodes_[parent].kids;
    const int index = in_.ConsumeIntegralInRange<int>(0, (int)kids.size());
    kids.insert(kids.begin() + index, child);
    nodes_[child].parent = parent;
    list_.push_back(react::ShadowViewMutation::InsertMutation(parent, nodes_[child].view, index));
  }

  void Remove() {
    const react::Tag child = PickTag(false);
    const react::Tag parent = nodes_[child].parent;
    if (parent == 0) return;
    auto& kids = nodes_[parent].kids;
    const auto it = std::find(kids.begin(), kids.end(), child);
    const int index = (int)(it - kids.begin());
    kids.erase(it);
    nodes_[child].parent = 0;
    list_.push_back(react::ShadowViewMutation::RemoveMutation(parent, nodes_[child].view, index));
  }

  void Delete() {
    const react::Tag tag = PickTag(false);
    if (tag == 1 || nodes_[tag].parent != 0 || !nodes_[tag].kids.empty()) return;
    list_.push_back(react::ShadowViewMutation::DeleteMutation(nodes_[tag].view));
    nodes_.erase(tag);
  }

  void Update() {
    const react::Tag tag = PickTag(false);
    Node& n = nodes_[tag];
    auto props = MakeProps(*n.desc, n.view.props, GenObject(in_, 3));
    if (!props) return;
    react::ShadowView next = View(*n.desc, tag, props);
    list_.push_back(react::ShadowViewMutation::UpdateMutation(n.view, next, n.parent));
    n.view = next;
  }

  FuzzedDataProvider& in_;
  std::map<react::Tag, Node> nodes_;
  react::ShadowViewMutation::List list_;
  react::Tag next_{2};
};

}  // namespace

int Scene(const uint8_t* data, size_t size) {
  if (size > 16384) return 0;
  FuzzedDataProvider in(data, size);
  auto scene = NewScene();
  Model model(in);
  for (int steps = 0; steps < 400 && in.remaining_bytes() > 0; ++steps) model.Step(*scene);
  model.Commit(*scene);
  scene->tabOrder();
  return 0;
}

}  // namespace rni::fuzz
