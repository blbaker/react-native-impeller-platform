// UTF-8 byte offsets <-> UTF-16 code units. The engine's edit buffer is UTF-8
// and its caret a byte offset; RN's selection events and UIKit's NSString
// indices are UTF-16 code units. Defined in FabricHost.cpp.
#pragma once

#include <cstddef>
#include <string>

namespace rni {

// A codepoint above U+FFFF is 2 units (a surrogate pair), anything else 1,
// whatever its UTF-8 length.
size_t Utf8OffsetToUtf16Units(const std::string& s, size_t byteOffset);
// The inverse. Clamps to the end, never lands inside a UTF-8 sequence, and a
// unit count that would split a surrogate pair rounds up past the codepoint.
size_t Utf16UnitsToUtf8Offset(const std::string& s, size_t units);

}  // namespace rni
