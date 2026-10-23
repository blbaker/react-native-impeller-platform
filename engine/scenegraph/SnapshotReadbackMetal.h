// ENG-47: view snapshots on native Metal. See SnapshotReadbackMetal.mm.
#pragma once

#include "scenegraph/GpuBackend.h"

// Darwin builds with the Metal window backend and SDK patch 0005 (wrapped
// Metal textures + ImpellerSurfaceReadPixels), the same gate as
// RNI_HEADLESS_METAL in host/HeadlessSurface.h.
#if defined(__APPLE__) && defined(RNI_WITH_WINDOW) && defined(IMPELLER_RNI_SURFACE_READBACK)
#define RNI_SNAPSHOT_METAL 1
#else
#define RNI_SNAPSHOT_METAL 0
#endif

namespace rni {

#if RNI_SNAPSHOT_METAL
// Renders a snapshot's display list into a fresh offscreen MTLTexture and
// reads it back as top-left RGBA8. ctx must be a Metal context.
SnapshotReadback MakeMetalSnapshotReadback(ImpellerContext ctx);
#endif

}  // namespace rni
