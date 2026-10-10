// <TextInput> text attributes that Text already honours (SC-20). One struct on
// the node, applied by the one paragraph builder paint, caret, click and
// selection all share, so they cannot disagree about glyph positions.
#pragma once

#include "impeller.h"

namespace rni {

struct TextInputFace {
  int align = 0;  // react::TextAlignment: 0 Natural 1 Left 2 Center 3 Right 4 Justified
  int weight = 0;
  bool italic = false;
  float letterSpacing = 0.0f;  // SC-33
  int fontVariant = 0;         // SC-33, react::FontVariant bits
  int decoLine = 0;
  int decoStyle = 0;
  int transform = 0;  // react::TextTransform
  bool hasDecoColor = false;
  float decoColor[4]{0.0f, 0.0f, 0.0f, 1.0f};
  bool hasCursorColor = false;
  float cursorColor[4]{0.0f, 0.0f, 0.0f, 1.0f};
  bool caretHidden = false;
};

// Advance-changing attributes: measured AND painted. Alignment is paint only
// and only for a wrapping (multiline) paragraph; a single-line field is laid
// out unwrapped, so SceneGraph shifts it by TextInputAlignDx instead.
void ApplyTextInputFace(ImpellerParagraphStyle style, const TextInputFace& f, bool multiline);

}  // namespace rni
