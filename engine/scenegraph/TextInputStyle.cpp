#include "scenegraph/TextInputStyle.h"

#include "text/TextStyle.h"

namespace rni {

void ApplyTextInputFace(ImpellerParagraphStyle style, const TextInputFace& f, bool multiline) {
  ApplyFontWeight(style, f.weight);
  ApplyFontStyle(style, f.italic);
  if (multiline) ApplyTextAlign(style, f.align);
}

}  // namespace rni
