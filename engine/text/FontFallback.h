#pragma once
// SC-19: per-glyph font fallback on linux. Impeller's font collection does not
// fall back for glyphs the primary face lacks (emoji, CJK, Arabic paint as tofu),
// so the text is split into runs by which face covers each codepoint, asking
// fontconfig for a covering face and registering its file with Impeller. Measure
// and paint both call it. Darwin (CoreText) and win32 fall back natively and get
// one segment back.
#include <impeller.h>

#include <string>
#include <vector>

namespace rni {

struct FontSegment {
  std::string family;  // "" = the caller's own family; else the fallback face
  std::string text;
};

// `primary` is the resolved family ("" = Impeller's default face).
std::vector<FontSegment> SplitFontFallback(ImpellerTypographyContext typography,
                                           const std::string& primary,
                                           const std::string& text);

// Sets the family for one segment: the fallback face, else `primary`; a
// multi-segment text on the default face pins sans-serif so the pieces match.
void ApplySegmentFamily(ImpellerParagraphStyle style, const std::string& primary,
                        const FontSegment& seg, bool singleSegment);

}  // namespace rni
