// Shared textTransform application. RN core keeps `fragment.string` in its raw
// case and leaves the transform to the platform (see BaseTextProps.cpp — it only
// converts the enum, never touches the string), so BOTH the paint path
// (SceneGraph) and the measure path (ImpellerTextLayoutManager) must apply it,
// from the SAME function, or an uppercased label measures narrower than it
// paints and the last glyphs clip.
//
// Enum order matches facebook::react::TextTransform:
//   0 None, 1 Uppercase, 2 Lowercase, 3 Capitalize, 4 Unset.
//
// ASCII-scope on purpose: RN's own web-parity transform is locale-unaware on the
// toUpper/toLower path, and the HostApp v5 labels this exists for (buttons, headers)
// are ASCII. A non-ASCII byte is left untouched rather than corrupted.
#pragma once

#include <cctype>
#include <string>

namespace rni {

inline std::string applyTextTransform(const std::string& in, int transform) {
  if (transform != 1 && transform != 2 && transform != 3) return in;  // None/Unset
  std::string out = in;
  bool atWordStart = true;
  for (char& ch : out) {
    const unsigned char uc = (unsigned char)ch;
    const bool isSpace = (uc == ' ' || uc == '\t' || uc == '\n' || uc == '\r' ||
                          uc == '\f' || uc == '\v');
    if (transform == 1) {  // Uppercase
      if (uc < 0x80) ch = (char)std::toupper(uc);
    } else if (transform == 2) {  // Lowercase
      if (uc < 0x80) ch = (char)std::tolower(uc);
    } else if (transform == 3) {  // Capitalize
      if (isSpace) {
        atWordStart = true;
      } else {
        if (atWordStart && uc < 0x80) ch = (char)std::toupper(uc);
        atWordStart = false;
      }
    }
  }
  return out;
}

}  // namespace rni
