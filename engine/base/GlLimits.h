// FP-16: GL limits the host reads once per context (Flutter reads the same one
// through Allocator::GetMaxTextureSizeSupported, impeller/renderer/backend/gles).
#pragma once

namespace rni::gllimits {

using ProcLoader = void* (*)(const char* name, void* userData);

// GL_MAX_TEXTURE_SIZE of the current context, or 0 if it cannot be read.
int MaxTextureSize(ProcLoader loader, void* userData);

}  // namespace rni::gllimits
