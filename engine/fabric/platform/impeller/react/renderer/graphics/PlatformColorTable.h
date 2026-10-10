// iOS semantic and Android attr/resource colours, light and dark.
#pragma once

#include <atomic>
#include <cstring>
#include <string>

namespace facebook::react::impeller_platform_color {

// Set by the host's Appearance state; read when a PlatformColor prop is parsed.
inline std::atomic<bool>& darkScheme() {
  static std::atomic<bool> dark{false};
  return dark;
}

struct Rgba {
  unsigned char r, g, b;
  float a;
};

struct Entry {
  const char* name;
  Rgba light;
  Rgba dark;
};

// Defined in fabric/platform/impeller/PlatformColorTable.cpp (rn-impeller).
const Entry* find(const std::string& raw);

} // namespace facebook::react::impeller_platform_color
