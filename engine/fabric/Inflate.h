#pragma once

// FP-16: streaming zlib (RFC 1950/1951) decoder. The compressed input is one
// in-memory buffer (encoded images are small); the OUTPUT is handed to `sink`
// in chunks of at most 64 KB, so a decode never holds more than the 32 KB
// window however large the inflated data is. PngStream feeds scanlines from it.

#include <cstddef>
#include <cstdint>

namespace rni::image {

// Return false to stop early (InflateZlib then returns true).
using InflateSink = bool (*)(void* user, const uint8_t* data, size_t n);

// False on a malformed stream.
bool InflateZlib(const uint8_t* src, size_t n, InflateSink sink, void* user);

}  // namespace rni::image
