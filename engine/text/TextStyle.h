#pragma once
// Style audit items 5, 7, 9: fontWeight, textAlign, textDecoration*.
//
// One set of setters shared by MEASURE (ImpellerTextLayoutManager) and PAINT
// (SceneGraph Paragraph), the same contract as text/LineHeight.h: a bold label
// measured in the regular face would be sized too narrow and clip its last
// glyph. Inputs are RN's own enum values as ints, so this header needs no
// react includes:
//   fontWeight  react::FontWeight             100..900, 0 = unset
//   align       react::TextAlignment          0 Natural, 1 Left, 2 Center,
//                                             3 Right, 4 Justified
//   decoLine    react::TextDecorationLineType 0 None, 1 Underline,
//                                             2 Strikethrough, 3 both
//   decoStyle   react::TextDecorationStyle    0 Solid, 1 Double, 2 Dotted,
//                                             3 Dashed
//
// Only fontWeight changes glyph advances, so only it is applied at measure.
// Alignment moves lines inside the layout width and decorations paint over
// laid-out glyphs; neither changes LongestLineWidth or Height.

#include "impeller.h"

namespace rni {

inline bool ApplyFontWeight(ImpellerParagraphStyle style, int weight) {
  if (weight <= 0) return false;  // unset: Impeller's default (400)
  int idx = (weight + 50) / 100;  // nearest hundred, 1..9
  if (idx < 1) idx = 1;
  if (idx > 9) idx = 9;
  ImpellerParagraphStyleSetFontWeight(style,
                                      (ImpellerFontWeight)(kImpellerFontWeight100 + idx - 1));
  return true;
}

// Measured AND painted: an italic face has different advances.
inline bool ApplyFontStyle(ImpellerParagraphStyle style, bool italic) {
  if (!italic) return false;
  ImpellerParagraphStyleSetFontStyle(style, kImpellerFontStyleItalic);
  return true;
}

// RN WritingDirection: 0 Natural, 1 LeftToRight, 2 RightToLeft. Sets the
// paragraph direction, which decides where Natural alignment starts.
inline bool ApplyTextDirection(ImpellerParagraphStyle style, int dir) {
  if (dir != 1 && dir != 2) return false;
  ImpellerParagraphStyleSetTextDirection(
      style, dir == 2 ? kImpellerTextDirectionRTL : kImpellerTextDirectionLTR);
  return true;
}

// Paint only. The paragraph must be laid out at the node's real width (not
// the 1e6 "unconstrained" width) or centre/right push the glyphs off-screen.
inline bool ApplyTextAlign(ImpellerParagraphStyle style, int align) {
  ImpellerTextAlignment a;
  switch (align) {
    case 1: a = kImpellerTextAlignmentLeft; break;
    case 2: a = kImpellerTextAlignmentCenter; break;
    case 3: a = kImpellerTextAlignmentRight; break;
    case 4: a = kImpellerTextAlignmentJustify; break;
    default: return false;  // Natural: Impeller's default (start)
  }
  ImpellerParagraphStyleSetTextAlignment(style, a);
  return true;
}

// Paint only. `color` is textDecorationColor when set, else the text colour
// (RN and CSS both default the decoration to currentColor).
inline bool ApplyTextDecoration(ImpellerParagraphStyle style, int decoLine,
                                int decoStyle, ImpellerColor color) {
  int types = kImpellerTextDecorationTypeNone;
  if (decoLine == 1 || decoLine == 3) types |= kImpellerTextDecorationTypeUnderline;
  if (decoLine == 2 || decoLine == 3) types |= kImpellerTextDecorationTypeLineThrough;
  if (types == kImpellerTextDecorationTypeNone) return false;
  ImpellerTextDecoration d{};
  d.types = types;
  d.color = color;
  switch (decoStyle) {
    case 1: d.style = kImpellerTextDecorationStyleDouble; break;
    case 2: d.style = kImpellerTextDecorationStyleDotted; break;
    case 3: d.style = kImpellerTextDecorationStyleDashed; break;
    default: d.style = kImpellerTextDecorationStyleSolid; break;
  }
  d.thickness_multiplier = 1.0f;
  ImpellerParagraphStyleSetTextDecoration(style, &d);
  return true;
}

// SC-33: letterSpacing (px, added after every glyph, so measure and paint
// must both apply it). NaN or 0 = unset.
inline bool ApplyLetterSpacing(ImpellerParagraphStyle style, float spacing) {
#ifdef IMPELLER_RNI_TEXT_EXTENSIONS
  if (!(spacing == spacing) || spacing == 0.0f) return false;
  ImpellerParagraphStyleSetLetterSpacing(style, spacing);
  return true;
#else
  (void)style;
  (void)spacing;
  return false;
#endif
}

// SC-33: fontVariant as react::FontVariant bits (SmallCaps 1<<1, OldstyleNums
// 1<<2, LiningNums 1<<3, TabularNums 1<<4, ProportionalNums 1<<5,
// StylisticOne..Twenty 1<<6..1<<25). As iOS (RCTFontUtils adds them in this
// order and the later one of a feature type wins): proportional beats
// tabular, lining beats oldstyle. Features change advances: measured too.
inline bool ApplyFontVariant(ImpellerParagraphStyle style, int variant) {
#ifdef IMPELLER_RNI_TEXT_EXTENSIONS
  if (variant == 0) return false;
  if (variant & (1 << 1)) ImpellerParagraphStyleSetFontFeature(style, "smcp", 1);
  if (variant & (1 << 3)) {
    ImpellerParagraphStyleSetFontFeature(style, "lnum", 1);
  } else if (variant & (1 << 2)) {
    ImpellerParagraphStyleSetFontFeature(style, "onum", 1);
  }
  if (variant & (1 << 5)) {
    ImpellerParagraphStyleSetFontFeature(style, "pnum", 1);
  } else if (variant & (1 << 4)) {
    ImpellerParagraphStyleSetFontFeature(style, "tnum", 1);
  }
  for (int i = 1; i <= 20; ++i) {
    if (!(variant & (1 << (i + 5)))) continue;
    const char tag[5] = {'s', 's', (char)('0' + i / 10), (char)('0' + i % 10), 0};
    ImpellerParagraphStyleSetFontFeature(style, tag, 1);
  }
  return true;
#else
  (void)style;
  (void)variant;
  return false;
#endif
}

// SC-34: an inline <View> inside <Text> is a placeholder box sized from the
// child's layout, bottom on the alphabetic baseline (RN iOS NSTextAttachment).
// Measure and paint both add it so the glyphs after it shift by its width.
inline bool AddAttachmentPlaceholder(ImpellerParagraphBuilder builder, float w, float h) {
#ifdef IMPELLER_RNI_TEXT_EXTENSIONS
  if (!(w == w) || !(h == h)) return false;
  w = w > 0 ? w : 0.0f;
  h = h > 0 ? h : 0.0f;
  ImpellerParagraphBuilderAddPlaceholder(builder, w, h, kImpellerPlaceholderAlignmentBaseline, h);
  return true;
#else
  (void)builder;
  (void)w;
  (void)h;
  return false;
#endif
}

}  // namespace rni
