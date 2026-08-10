// ImpellerTextLayoutManager — real text measurement, backed by Impeller's
// bundled typography engine (ICU + shaping included in the standalone SDK).
//
// ⛔ WHY THIS MUST EXIST BEFORE ANY TEXT CAN WORK
//
// RN's platform/cxx TextLayoutManager is a STUB: its measure() returns
// `layoutConstraints.minimumSize`, i.e. 0x0 for a normal <Text>. Nothing errors
// — ParagraphShadowNode measures 0x0, Yoga lays out a zero-sized box, the node
// mounts, the mutation log looks perfectly healthy, and no text appears. That is
// the same "reports success at every layer, produces no effect" failure class
// that hid for nine phases on the sibling project, so it is fixed here in the
// same phase that first mounts a <Text>.
//
// The ContextContainer insert in FabricHost is the other half: ParagraphComponent
// Descriptor pulls this out by name, and it MUST be inserted as the BASE-type
// std::shared_ptr<TextLayoutManager> or the lookup misses and RN silently news
// the stub above.
#pragma once

#include <react/renderer/textlayoutmanager/TextLayoutManager.h>

#include <memory>

#include "impeller.h"

namespace rni {

class ImpellerTextLayoutManager : public facebook::react::TextLayoutManager {
 public:
  ImpellerTextLayoutManager(
      const std::shared_ptr<const facebook::react::ContextContainer>& contextContainer,
      ImpellerTypographyContext typography);

  facebook::react::TextMeasurement measure(
      const facebook::react::AttributedStringBox& attributedStringBox,
      const facebook::react::ParagraphAttributes& paragraphAttributes,
      const facebook::react::TextLayoutContext& layoutContext,
      const facebook::react::LayoutConstraints& layoutConstraints) const override;

 private:
  ImpellerTypographyContext typography_{nullptr};
};

}  // namespace rni
