// iOS host phase: the GL-side entry points shared engine code names, on a
// platform with no GL. iOS is Metal only (docs/eng/ios-platform.md); the GL
// translation units (scenegraph/*Gl.cpp, base/Gl*.cpp) are not compiled for it.
// Each definition here answers "no GL", the same answers those TUs give when
// GL is unavailable (scenegraph/GpuBackend.h: "GL ones ... are empty when GL is
// not available").
#include "scenegraph/GpuBackend.h"
#include "scenegraph/IoUploader.h"

namespace rni {

// GpuBackend.h: "GL ones ... are empty when GL is not available". Metal and
// Vulkan take MakeContentsUploader (ImpellerTextureCreateWithContentsNew).
GlParts MakeGlParts(ImpellerContext) { return {}; }

}  // namespace rni

namespace rni::io {

// IoUploader.h: "0 when the IO thread did not upload it". There is no GL IO
// thread on iOS (FP-17 is a GL share-group hand-off), so nothing is ever ready.
uint32_t Take(const image::Decoded*) { return 0; }

}  // namespace rni::io
