#include "host/Pixel.h"

#include <cstdio>

namespace rni {

bool WritePpm(const std::string& path, const std::vector<Px>& px, int width,
              int height) {
  // "wb" matters on Windows: a text-mode stream translates every 0x0A byte in
  // the BINARY pixel payload into 0x0D 0x0A, producing a file that is longer
  // than its own header claims and decodes as garbage. On Linux the mode is a
  // no-op, which is exactly why this is easy to get wrong in a port.
  FILE* f = std::fopen(path.c_str(), "wb");
  if (!f) return false;
  std::fprintf(f, "P6\n%d %d\n255\n", width, height);
  for (const auto& p : px) std::fwrite(&p, 1, 3, f);
  std::fclose(f);
  return true;
}

}  // namespace rni
