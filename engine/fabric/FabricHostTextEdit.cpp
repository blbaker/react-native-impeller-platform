// Range editing for hosts whose text system edits by range (iOS UITextInput).
// See FabricHost.h ("Range editing"). Own TU so FabricHost.cpp does not grow;
// the event tail mirrors dispatchKey's (FabricHost.cpp) exactly: paint buffer
// first, then onChange (only when the text changed) and onSelectionChange
// with a UTF-16 selection, then onContentSizeChange.
#include <react/renderer/components/textinput/TextInputEventEmitter.h>
#include <react/renderer/runtimescheduler/RuntimeScheduler.h>

#include <algorithm>
#include <cstdio>

#include "fabric/FabricHost.h"
#include "fabric/Utf16Offsets.h"
#include "scenegraph/SceneGraph.h"

namespace rni {

namespace react = facebook::react;

bool FabricHost::textInputState(TextInputState* out) {
  if (!sceneGraph_) return false;
  const react::Tag tag = sceneGraph_->focusedTextInput();
  if (tag == 0) return false;
  const std::string value = sceneGraph_->textInputValueFor(tag);
  const size_t caret = std::min(sceneGraph_->textInputCaretFor(tag), value.size());
  const size_t anchor = std::min(sceneGraph_->textInputSelectionAnchorFor(tag), value.size());
  out->tag = (int)tag;
  out->value = value;
  out->selStart = Utf8OffsetToUtf16Units(value, std::min(anchor, caret));
  out->selEnd = Utf8OffsetToUtf16Units(value, std::max(anchor, caret));
  return true;
}

int FabricHost::replaceTextInputRange(size_t start, size_t end, const std::string& text,
                                      size_t selStart, size_t selEnd) {
  if (!sceneGraph_ || !runtimeScheduler_) return 0;
  const react::Tag tag = sceneGraph_->focusedTextInput();
  if (tag == 0) return 0;
  auto te = std::dynamic_pointer_cast<const react::TextInputEventEmitter>(
      sceneGraph_->eventEmitterFor(tag));
  if (!te) return 0;

  std::string value = sceneGraph_->textInputValueFor(tag);
  const size_t lo = Utf16UnitsToUtf8Offset(value, std::min(start, end));
  const size_t hi = Utf16UnitsToUtf8Offset(value, std::max(start, end));
  const bool textChanged = hi != lo || !text.empty();
  if (textChanged) value.replace(lo, hi - lo, text);
  const size_t anchor = Utf16UnitsToUtf8Offset(value, std::min(selStart, selEnd));
  const size_t caret = Utf16UnitsToUtf8Offset(value, std::max(selStart, selEnd));

  if (anchor == caret) {
    sceneGraph_->setTextInputEdit(tag, value, caret);
  } else {
    sceneGraph_->setTextInputSelection(tag, value, anchor, caret);
  }
  std::printf("rn-impeller: ti_replace tag=%d range=%zu,%zu bytes=%zu sel=%zu,%zu len=%zu\n",
              (int)tag, start, end, text.size(), selStart, selEnd, value.size());
  std::fflush(stdout);

  react::TextInputEventEmitter::Metrics m{};
  m.text = value;
  m.eventCount = ++tiEventCount_;
  if (textChanged) lastChangeEventCount_[(int)tag] = m.eventCount;
  const int loUnits = (int)Utf8OffsetToUtf16Units(value, anchor);
  const int hiUnits = (int)Utf8OffsetToUtf16Units(value, caret);
  m.selectionRange.location = loUnits;
  m.selectionRange.length = hiUnits - loUnits;
  runtimeScheduler_->scheduleWork([te, m, textChanged](facebook::jsi::Runtime&) {
    if (textChanged) te->onChange(m);
    te->onSelectionChange(m);
  });
  if (textChanged) emitContentSizeIfChanged((int)tag);
  return (int)tag;
}

bool FabricHost::textInputCaretRect(size_t offset, float* x, float* y, float* w, float* h) {
  if (!sceneGraph_) return false;
  const react::Tag tag = sceneGraph_->focusedTextInput();
  if (tag == 0) return false;
  const std::string value = sceneGraph_->textInputValueFor(tag);
  return sceneGraph_->textInputCaretRect(tag, Utf16UnitsToUtf8Offset(value, offset), x, y, w,
                                         h);
}

bool FabricHost::textInputKeyboardTraits(TextInputKeyboardTraits* out) {
  if (!sceneGraph_) return false;
  const react::Tag tag = sceneGraph_->focusedTextInput();
  return tag != 0 && sceneGraph_->textInputKeyboardTraits(tag, out);
}

}  // namespace rni
