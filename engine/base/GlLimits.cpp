#include "base/GlLimits.h"

namespace rni::gllimits {

int MaxTextureSize(ProcLoader loader, void* userData) {
  using GetIntegerv = void (*)(unsigned int pname, int* data);
  constexpr unsigned int kGlMaxTextureSize = 0x0D33;
  auto get = reinterpret_cast<GetIntegerv>(loader("glGetIntegerv", userData));
  if (get == nullptr) return 0;
  int v = 0;
  get(kGlMaxTextureSize, &v);
  return v > 0 ? v : 0;
}

}  // namespace rni::gllimits
