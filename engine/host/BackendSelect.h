// FP-21: which GPU backend a run gets. darwin windowed defaults to native Metal
// (Flutter macOS/iOS render with Metal only: ios_surface_metal_impeller.mm);
// darwin headless defaults to ANGLE GLES; `--headless --backend metal` renders
// into an offscreen MTLTexture (FP-23, SDK patch 0005). linux/win32 are GLES (Flutter: fl_engine.cc,
// windows/egl/manager.cc).
#pragma once

#include <string>

#include "scenegraph/GpuBackend.h"

namespace rni {

// window: a --window run (not --headless). given: --backend was passed, and
// *backend holds it. Fills *backend; false + *error when the combination is refused.
bool ResolveGpuBackend(bool window, bool given, GpuBackend* backend, std::string* error);

}  // namespace rni
