#include "text/ImpellerTextLayoutManager.h"

#include <react/renderer/attributedstring/AttributedString.h>

#include <algorithm>
#include <cmath>

namespace rni {

namespace react = facebook::react;

ImpellerTextLayoutManager::ImpellerTextLayoutManager(
    const std::shared_ptr<const react::ContextContainer>& contextContainer,
    ImpellerTypographyContext typography)
    : react::TextLayoutManager(contextContainer), typography_(typography) {}

react::TextMeasurement ImpellerTextLayoutManager::measure(
    const react::AttributedStringBox& attributedStringBox,
    const react::ParagraphAttributes& paragraphAttributes,
    const react::TextLayoutContext& /*layoutContext*/,
    const react::LayoutConstraints& layoutConstraints) const {
  react::TextMeasurement::Attachments attachments;
  const auto& attributedString = attributedStringBox.getValue();

  for (const auto& fragment : attributedString.getFragments()) {
    if (fragment.isAttachment()) {
      // Inline views: reported at zero for now. Their own shadow nodes still
      // lay out; only their in-line placement is unimplemented.
      attachments.push_back(react::TextMeasurement::Attachment{
          .frame = {.origin = {.x = 0, .y = 0}, .size = {.width = 0, .height = 0}},
          .isClipped = false});
    }
  }

  if (typography_ == nullptr || attributedString.isEmpty()) {
    return react::TextMeasurement{
        .size = {.width = 0, .height = 0}, .attachments = attachments};
  }

  ImpellerParagraphBuilder builder = ImpellerParagraphBuilderNew(typography_);
  if (builder == nullptr) {
    return react::TextMeasurement{
        .size = {.width = 0, .height = 0}, .attachments = attachments};
  }

  // One style push per fragment, so per-fragment font size/weight is honoured
  // rather than the whole string being measured at the first fragment's size.
  for (const auto& fragment : attributedString.getFragments()) {
    if (fragment.isAttachment()) continue;
    ImpellerParagraphStyle style = ImpellerParagraphStyleNew();
    const auto& attrs = fragment.textAttributes;
    float fontSize = attrs.fontSize > 0 ? (float)attrs.fontSize : 14.0f;
    ImpellerParagraphStyleSetFontSize(style, fontSize);
    if (!attrs.fontFamily.empty()) {
      ImpellerParagraphStyleSetFontFamily(style, attrs.fontFamily.c_str());
    }
    if (paragraphAttributes.maximumNumberOfLines > 0) {
      ImpellerParagraphStyleSetMaxLines(
          style, (uint32_t)paragraphAttributes.maximumNumberOfLines);
    }
    ImpellerParagraphBuilderPushStyle(builder, style);
    ImpellerParagraphBuilderAddText(
        builder, (const uint8_t*)fragment.string.c_str(), fragment.string.size());
    ImpellerParagraphBuilderPopStyle(builder);
    ImpellerParagraphStyleRelease(style);
  }

  // An unconstrained <Text> arrives with maximumSize.width == infinity, which is
  // not a number Impeller can lay out against — clamp to a large finite width so
  // the paragraph reports its natural single-line width instead of NaN.
  float maxWidth = (float)layoutConstraints.maximumSize.width;
  if (!std::isfinite(maxWidth) || maxWidth <= 0) maxWidth = 1e6f;

  ImpellerParagraph paragraph =
      ImpellerParagraphBuilderBuildParagraphNew(builder, maxWidth);
  ImpellerParagraphBuilderRelease(builder);
  if (paragraph == nullptr) {
    return react::TextMeasurement{
        .size = {.width = 0, .height = 0}, .attachments = attachments};
  }

  // LongestLineWidth, not MaxWidth: MaxWidth returns the constraint we passed
  // in, so using it would size every <Text> to the full available width and the
  // error would be invisible on a full-width label.
  float width = ImpellerParagraphGetLongestLineWidth(paragraph);
  float height = ImpellerParagraphGetHeight(paragraph);
  ImpellerParagraphRelease(paragraph);

  width = std::clamp(width, (float)layoutConstraints.minimumSize.width,
                     (float)layoutConstraints.maximumSize.width);
  height = std::clamp(height, (float)layoutConstraints.minimumSize.height,
                      (float)layoutConstraints.maximumSize.height);

  return react::TextMeasurement{.size = {.width = width, .height = height},
                                .attachments = attachments};
}

}  // namespace rni
