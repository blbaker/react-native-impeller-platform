#include "fabric/ComponentRegistry.h"

#include <react/renderer/componentregistry/ComponentDescriptorProviderRegistry.h>
#include <react/renderer/components/iostextinput/TextInputComponentDescriptor.h>
#include <react/renderer/components/image/ImageComponentDescriptor.h>
#include <react/renderer/components/root/RootComponentDescriptor.h>
#include <react/renderer/components/scrollview/ScrollViewComponentDescriptor.h>
#include <react/renderer/components/text/ParagraphComponentDescriptor.h>
#include <react/renderer/components/text/RawTextComponentDescriptor.h>
#include <react/renderer/components/text/TextComponentDescriptor.h>
#include <react/renderer/components/view/ViewComponentDescriptor.h>

#include "ActivityIndicatorShadowNode.h"
#include "ModalHostShadowNode.h"
#include "SwitchShadowNode.h"
#include "TextureViewShadowNode.h"
#if RNI_WITH_RNSVG
#include "RNSVGComponentDescriptors.h"
#include <react/renderer/components/rnsvg/ComponentDescriptors.h>
#include "fabric/WorldShadowNode.h"
#endif

namespace rni {

namespace react = facebook::react;

std::shared_ptr<const react::ComponentDescriptorProviderRegistry>
MakeComponentProviderRegistry() {
  auto providerRegistry =
      std::make_shared<const react::ComponentDescriptorProviderRegistry>();
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RootComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ViewComponentDescriptor>());
  // <Text>: Paragraph is the measurable leaf; Text/RawText are virtual.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ParagraphComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::TextComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RawTextComponentDescriptor>());
  // <ScrollView>. ENG-02.
  //
  // ⛔ REGISTRATION IS THE WHOLE FEATURE'S FLOOR, NOT A DETAIL.
  // Without this line a <ScrollView> still MOUNTS -- as a plain View with
  // ViewProps -- lays out, paints its children, and logs nothing wrong. It is
  // indistinguishable from "scrolling is unimplemented" by reading paint code,
  // which is why this add() is checked before any painter change.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ScrollViewComponentDescriptor>());
  // <TextInput>. ENG-01b.
  //
  // ⛔ REGISTRATION IS THE FLOOR, AND FOR TextInput IT IS ALSO WHERE MEASUREMENT
  // COMES FROM. BaseTextInputShadowNode::measureContent asks for a
  // TextLayoutManager via getManagerByName, so this descriptor MUST see the same
  // ImpellerTextLayoutManager that <Text> uses (inserted into contextContainer
  // below) or the field measures 0x0 and its own value text never lays out.
  // Unregistered, <TextInput> mounts as a plain View: it paints its border,
  // swallows every keystroke, and logs nothing wrong -- byte-for-byte the
  // read-only surface the Mac gate is currently pinned to.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::TextInputComponentDescriptor>());
  // <Switch>. ENG-15. Same floor as above: unregistered, a <Switch> mounts as
  // a plain View, measures 0 x 0 and paints nothing (audit tile 62). See
  // fabric/SwitchShadowNode.h.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ImpellerSwitchComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ImpellerActivityIndicatorComponentDescriptor>());
  // <Modal>. A22: a window-sized layout root painted after the app root.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ImpellerModalHostComponentDescriptor>());
  // <Image>. A19: RN's ImageShadowNode ("Image", from RCTImageView) with OUR
  // ImageManager (fabric/platform/impeller/.../ImageManager.cpp).
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ImageComponentDescriptor>());
  // FP-42 <ImpellerTextureView textureId>: paints a TextureRegistry frame.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::ImpellerTextureViewComponentDescriptor>());
#if RNI_WITH_RNSVG
  // <world>. ENG-09. See fabric/WorldShadowNode.h for why this borrows
  // RNSVGImageProps/EventEmitter rather than getting its own codegen pair --
  // registration here is the floor, same as every other host component:
  // unregistered, a mounted <world> falls back to a plain View with
  // ViewProps and paints nothing OF ITS OWN, silently.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::WorldComponentDescriptor>());
  // RNSVGSvgView's ComponentDescriptor is OUR codegen output (react-native-svg's
  // Svg.js resolves to the platform-suffixed name, which only the codegen
  // emits); Group/Path use the vendor's own hand-written `using` aliases.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGSvgViewComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGGroupComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGPathComponentDescriptor>());
  // The basic shapes. Each is converted to path data in SceneGraph and painted
  // by the SAME fill/stroke code as <Path>, so registering them costs a line
  // here and nothing in the painter.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGRectComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGCircleComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGEllipseComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGLineComponentDescriptor>());
  // <Defs> paints nothing -- it is a container for definitions -- but it MUST
  // be registered or its gradient children never mount and every url(#id)
  // reference silently resolves to nothing.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGDefsComponentDescriptor>());
  // <Symbol> + <Use>: one asset, N mounting sites.
  //
  // ⚠️ REGISTERING THESE IS NOT WHAT FIXED THEM, AND THAT IS THE LESSON.
  // Unregistered, <Symbol> mounted with plain ViewProps and painted nothing OF
  // ITS OWN -- but its <Path> children were registered, so the painter walked
  // into them and drew the DEFINITION at the defs block's own coordinates. The
  // symptom was not a missing logo, it was a stray logo somewhere nobody was
  // probing. Registration lets us READ href/viewBox; SceneGraph's
  // isSvgDefinition early-return is what stops the leak. Both are required and
  // either alone is worse than neither.
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGSymbolComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGUseComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGLinearGradientComponentDescriptor>());
  providerRegistry->add(
      react::concreteComponentDescriptorProvider<react::RNSVGRadialGradientComponentDescriptor>());
#endif
  return providerRegistry;
}

}  // namespace rni
