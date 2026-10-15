#include "fuzz/FuzzFabric.h"

#include <react/renderer/componentregistry/ComponentDescriptorProviderRegistry.h>
#include <react/renderer/componentregistry/ComponentDescriptorRegistry.h>
#include <react/renderer/components/image/ImageComponentDescriptor.h>
#include <react/renderer/core/PropsParserContext.h>
#include <react/renderer/core/RawProps.h>
#include <react/renderer/imagemanager/ImageManager.h>
#include <react/utils/ContextContainer.h>

#include <folly/json.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <exception>

#include "fabric/ComponentRegistry.h"
#include "impeller.h"
#include "scenegraph/SceneGraph.h"
#include "text/ImpellerTextLayoutManager.h"
#include "text/TypographyContexts.h"

namespace rni::fuzz {

namespace react = facebook::react;

namespace {

// RootView first; the rest are what reaches mounting (FabricHost's registry
// minus Text/RawText, which are virtual and never produce a mutation).
constexpr const char* kNames[] = {
    "RootView", "View", "Paragraph", "ScrollView", "TextInput", "Switch",
    "ActivityIndicatorView", "ModalHostView", "Image",
#if RNI_WITH_RNSVG
    "world", "RNSVGSvgView", "RNSVGGroup", "RNSVGPath", "RNSVGRect", "RNSVGCircle",
    "RNSVGEllipse", "RNSVGLine", "RNSVGDefs", "RNSVGSymbol", "RNSVGUse",
    "RNSVGLinearGradient", "RNSVGRadialGradient",
#endif
};

struct Fixture {
  std::shared_ptr<const react::ComponentDescriptorProviderRegistry> providers;
  std::shared_ptr<react::ContextContainer> context;
  react::SharedComponentDescriptorRegistry registry;
  ImpellerTypographyContext typography{nullptr};
  const react::ComponentDescriptor* root{nullptr};
  std::vector<const react::ComponentDescriptor*> components;

  Fixture() {
    providers = MakeComponentProviderRegistry();
    context = std::make_shared<react::ContextContainer>();
    typography = ImpellerTypographyContextNew();
    if (typography == nullptr) std::abort();
    typography::Bind(typography);  // libFuzzer calls every input on this thread
    // The two managers the descriptors read at construction (as FabricHost).
    context->insert("TextLayoutManager",
                    std::shared_ptr<react::TextLayoutManager>(
                        std::make_shared<ImpellerTextLayoutManager>(context, true)));
    context->insert(react::ImageManagerKey, std::make_shared<react::ImageManager>(context));
    registry = providers->createComponentDescriptorRegistry({{}, context, nullptr});
    for (const char* name : kNames) {
      const react::ComponentDescriptor& d = registry->at(name);
      // A name the registry does not know resolves to a fallback: a fixture bug.
      if (std::string(d.getComponentName()) != name) {
        std::fprintf(stderr, "fuzz: component %s not registered (got %s)\n", name,
                     d.getComponentName());
        std::abort();
      }
      if (root == nullptr) root = &d; else components.push_back(&d);
    }
  }
};

// RN's JS style processors run BEFORE createNode (processColor, processFilter,
// processBoxShadow, processBackgroundImage in Libraries/StyleSheet), so for these
// keys C++ only ever sees their output. RN's converters trust that and crash on
// other shapes ([{}] for filter dereferences begin() of an empty map; a [r,g,b,a]
// colour array of 1e30 floats is a float-cast-overflow in HostPlatformColor.h):
// upstream code the JS contract keeps unreachable (fuzz seeds props/crash-rn-*,
// scene/crash-rn-*). Everything else reaches the converters as generated.
constexpr const char* kProcessed[] = {
    R"([{"blur":3},{"brightness":0.5},{"hue-rotate":90},{"drop-shadow":{"offsetX":1,"offsetY":1,"standardDeviation":2,"color":4278190080}}])",
    R"([{"offsetX":2,"offsetY":3,"blurRadius":4,"spreadDistance":-1,"color":4278190335,"inset":true}])",
    R"([{"type":"linear-gradient","direction":{"type":"angle","value":45},"colorStops":[{"color":4278190335},{"color":4294901760}]}])",
};

// Codegen enum props abort() on a string outside the enum (FBReactNativeSpec
// Props.h); the JS wrappers (ActivityIndicator.js, Modal.js) only pass these
// (fuzz seed scene/crash-rn-codegen-enum).
struct EnumProp {
  const char* component;
  const char* key;
  std::vector<std::string> values;
};
const std::vector<EnumProp>& EnumProps() {
  static const std::vector<EnumProp> props = {
      {"ActivityIndicatorView", "size", {"small", "large"}},
      {"ModalHostView", "animationType", {"none", "slide", "fade"}},
      {"ModalHostView", "presentationStyle", {"fullScreen", "pageSheet", "formSheet", "overFullScreen"}},
      {"ModalHostView", "supportedOrientations",
       {"portrait", "portrait-upside-down", "landscape", "landscape-left", "landscape-right"}},
  };
  return props;
}

bool IsEnumValue(const std::vector<std::string>& values, const folly::dynamic& v) {
  if (v.isNull()) return true;
  if (v.isString()) return std::find(values.begin(), values.end(), v.getString()) != values.end();
  if (!v.isArray()) return false;  // supportedOrientations is a list of them
  for (const auto& e : v) {
    if (!e.isString() || !IsEnumValue(values, e)) return false;
  }
  return true;
}

bool IsColorKey(const std::string& k) {
  return k == "color" || k.find("Color") != std::string::npos;  // trackColorForTrue too
}

// processColor's outputs: an ARGB uint32, null, or a PlatformColor object
// (our PlatformColorParser reads `semantic` / `resource_paths` string lists).
bool IsProcessedColor(const folly::dynamic& v) {
  if (v.isNull() || v.isObject()) return true;
  if (v.isInt()) return v.getInt() >= 0 && v.getInt() <= 0xFFFFFFFFLL;
  return v.isDouble() && v.getDouble() >= 0.0 && v.getDouble() <= 4294967295.0 &&
         v.getDouble() == (double)(int64_t)v.getDouble();
}

folly::dynamic AsJsEmits(const std::string& component, const folly::dynamic& raw) {
  static const std::vector<folly::dynamic> processed = [] {
    std::vector<folly::dynamic> out;
    for (const char* j : kProcessed) out.push_back(folly::parseJson(j));
    return out;
  }();
  folly::dynamic out = folly::dynamic::object();
  for (const auto& [k, v] : raw.items()) {
    if (!k.isString()) continue;
    const std::string key = k.getString();
    if (IsColorKey(key) && !IsProcessedColor(v)) continue;
    const auto& enums = EnumProps();
    const auto e = std::find_if(enums.begin(), enums.end(), [&](const EnumProp& p) {
      return component == p.component && key == p.key;
    });
    if (e != enums.end() && !IsEnumValue(e->values, v)) continue;
    if ((key == "filter" || key == "boxShadow" || key == "experimental_backgroundImage") &&
        !v.isNull() && std::find(processed.begin(), processed.end(), v) == processed.end()) {
      continue;
    }
    out[k] = v;
  }
  return out;
}

Fixture& Get() {
  static Fixture* f = new Fixture();  // lives for the process, like FabricHost's
  return *f;
}

}  // namespace

const std::vector<const react::ComponentDescriptor*>& Components() { return Get().components; }
const react::ComponentDescriptor& RootComponent() { return *Get().root; }

react::Props::Shared MakeProps(const react::ComponentDescriptor& desc,
                               const react::Props::Shared& base, const folly::dynamic& raw) {
  react::PropsParserContext ctx{1, *Get().context};
  try {
    return desc.cloneProps(ctx, base, react::RawProps(raw.isObject() ? AsJsEmits(desc.getComponentName(), raw) : raw));
  } catch (const std::exception&) {
    return nullptr;
  }
}

react::ShadowView MakeView(const react::ComponentDescriptor& desc, react::Tag tag,
                           react::Props::Shared props, float x, float y, float w, float h) {
  react::ShadowView v;
  v.componentName = desc.getComponentName();
  v.componentHandle = desc.getComponentHandle();
  v.surfaceId = 1;
  v.tag = tag;
  v.props = std::move(props);
  v.layoutMetrics.frame = {{x, y}, {w, h}};
  v.layoutMetrics.pointScaleFactor = 1.0f;
  return v;
}

int Record(SceneGraph& scene, float pointScale) {
  ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
  const int painted = scene.paint(b, pointScale);
  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);
  ImpellerDisplayListRelease(dl);
  ImpellerDisplayListBuilderRelease(b);
  return painted;
}

std::unique_ptr<SceneGraph> NewScene() {
  return std::make_unique<SceneGraph>(Get().typography);
}

}  // namespace rni::fuzz
