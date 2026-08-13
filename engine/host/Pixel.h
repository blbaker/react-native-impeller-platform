// Pixel — the platform-neutral half of the surface API.
//
// Extracted during the Windows port (P5). `Px` and `writePpm` were members of
// HeadlessSurface, which meant the Windows surface would have had to either
// duplicate them or inherit an EGL-flavoured base class. Neither is a real
// dependency: a pixel struct and a PPM writer have nothing to do with how the
// GL context was acquired.
//
// This is deliberately SHARED rather than duplicated per platform — the same
// reasoning as the openURL allowlist: code that only exists on one OS is
// unverifiable until someone builds that OS, which is precisely when it gets
// the least scrutiny. Both platforms compile this file every day.
#pragma once

#include <string>
#include <vector>

namespace rni {

struct Px {
  unsigned char r, g, b, a;
};

// Writes a binary PPM (P6). Chosen over PNG so the engine needs no image
// encoder; tooling converts. Pixels must ALREADY be in top-left order.
bool WritePpm(const std::string& path, const std::vector<Px>& px, int width,
              int height);

}  // namespace rni
