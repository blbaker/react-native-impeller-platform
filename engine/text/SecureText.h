#pragma once
// Style audit item 11: TextInput secureTextEntry.
//
// A secure field PAINTS one bullet per codepoint of its value, never the
// value. The masked string is what the painter draws AND what click-to-caret
// measures (glyphBoundariesLocked), so caret/selection math stays per
// codepoint: the mask keeps exactly one codepoint per source codepoint.
// The edit buffer and onChangeText keep the real value; only the pixels change.

#include <string>

namespace rni {

// U+2022 BULLET, the glyph UITextField and NSSecureTextField draw.
inline constexpr const char* kSecureBullet = "\xE2\x80\xA2";

// Returns `s` with every UTF-8 codepoint replaced by one bullet. Byte offsets
// change (one ASCII byte becomes three), so callers that map a source byte
// offset into the mask use SecureMaskOffset.
inline std::string SecureMask(const std::string& s) {
  std::string out;
  out.reserve(s.size() * 3);
  for (size_t i = 0; i < s.size(); ++i) {
    // A UTF-8 lead byte is any byte that is not 10xxxxxx.
    if ((((unsigned char)s[i]) & 0xC0) != 0x80) out += kSecureBullet;
  }
  return out;
}

// Byte offset in SecureMask(s) that corresponds to byte offset `n` in `s`.
inline size_t SecureMaskOffset(const std::string& s, size_t n) {
  size_t cps = 0;
  for (size_t i = 0; i < n && i < s.size(); ++i) {
    if ((((unsigned char)s[i]) & 0xC0) != 0x80) ++cps;
  }
  return cps * 3;
}

}  // namespace rni
