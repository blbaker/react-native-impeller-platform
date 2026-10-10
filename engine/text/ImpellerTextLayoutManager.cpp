#include "text/ImpellerTextLayoutManager.h"

#include <react/renderer/attributedstring/AttributedString.h>

#include <algorithm>
#include <cmath>

#include "text/FitScale.h"
#include "text/FontFamily.h"
#include "text/LineHeight.h"
#include "text/TextStyle.h"
#include "text/TextTransform.h"

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

  // An unconstrained <Text> arrives with maximumSize.width == infinity, which is
  // not a number Impeller can lay out against — clamp to a large finite width so
  // the paragraph reports its natural single-line width instead of NaN.
  float maxWidth = (float)layoutConstraints.maximumSize.width;
  if (!std::isfinite(maxWidth) || maxWidth <= 0) maxWidth = 1e6f;

  // clamp=false lays the text out with no line limit or ellipsis (SC-17 probe).
  const auto build = [&](float scale, bool clamp) -> ImpellerParagraph {
    ImpellerParagraphBuilder builder = ImpellerParagraphBuilderNew(typography_);
    if (builder == nullptr) return nullptr;
    // One style push per fragment, so per-fragment font size/weight is honoured
    // rather than the whole string being measured at the first fragment's size.
    for (const auto& fragment : attributedString.getFragments()) {
      if (fragment.isAttachment()) continue;
      ImpellerParagraphStyle style = ImpellerParagraphStyleNew();
      const auto& attrs = fragment.textAttributes;
      float fontSize = (attrs.fontSize > 0 ? (float)attrs.fontSize : 14.0f) * scale;
      ImpellerParagraphStyleSetFontSize(style, fontSize);
      if (!attrs.fontFamily.empty()) {
        ImpellerParagraphStyleSetFontFamily(
            style, rni::ResolveFontFamily(attrs.fontFamily).c_str());
      }
      // ENG-23: the same setter SceneGraph paints with (text/LineHeight.h).
      ApplyLineHeight(style, (float)attrs.lineHeight * scale, fontSize);
      // Style audit item 5: the SAME weight setter paint uses (text/TextStyle.h),
      // so a bold label is measured in the bold face's advances.
      ApplyFontWeight(style, attrs.fontWeight.has_value() ? (int)*attrs.fontWeight : 0);
      ApplyFontStyle(style, attrs.fontStyle.has_value() &&
                                *attrs.fontStyle != react::FontStyle::Normal);
      if (clamp && paragraphAttributes.maximumNumberOfLines > 0) {
        ImpellerParagraphStyleSetMaxLines(
            style, (uint32_t)paragraphAttributes.maximumNumberOfLines);
        // Ellipsis must be present at MEASURE time too, not just paint: an
        // ellipsized single line is measured to the clamp width, and omitting the
        // "…" here would let measure report a wider box than paint fills.
        if (paragraphAttributes.ellipsizeMode != react::EllipsizeMode::Clip) {
          ImpellerParagraphStyleSetEllipsis(style, "\xE2\x80\xA6");  // U+2026 …
        }
      }
      ImpellerParagraphBuilderPushStyle(builder, style);
      // textTransform is applied to the SAME string the painter draws (see
      // text/TextTransform.h). Measuring the raw case while painting the
      // transformed case would let an uppercased label clip its last glyphs.
      int transform = fragment.textAttributes.textTransform.has_value()
                          ? (int)fragment.textAttributes.textTransform.value()
                          : 0;
      const std::string measured = applyTextTransform(fragment.string, transform);
      ImpellerParagraphBuilderAddText(
          builder, (const uint8_t*)measured.c_str(), measured.size());
      ImpellerParagraphBuilderPopStyle(builder);
      ImpellerParagraphStyleRelease(style);
    }

    ImpellerParagraph paragraph =
        ImpellerParagraphBuilderBuildParagraphNew(builder, maxWidth);
    ImpellerParagraphBuilderRelease(builder);
    return paragraph;
  };

  // SC-17: the same FitFontScale search the painter runs (text/FitScale.h).
  const float fitScale = FitFontScale(
      paragraphAttributes.adjustsFontSizeToFit, (float)paragraphAttributes.minimumFontScale,
      paragraphAttributes.maximumNumberOfLines, maxWidth, [&](float s) {
        std::pair<int, float> r{0, 0.0f};
        if (ImpellerParagraph p = build(s, false)) {
          r = {(int)ImpellerParagraphGetLineCount(p), ImpellerParagraphGetLongestLineWidth(p)};
          ImpellerParagraphRelease(p);
        }
        return r;
      });
  ImpellerParagraph paragraph = build(fitScale, true);
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
