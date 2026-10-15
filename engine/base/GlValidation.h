// FP-05: KHR_debug validation on every GL context we create. Impeller's GLES backend
// has no debug-output callback of its own at our SDK pin (it only polls glGetError in
// debug builds), so the host installs one. Modes, from RNI_GL_VALIDATION:
//   unset / 0  off (a gl_validation=off line is printed at exit)
//   1          count GL_DEBUG_TYPE_ERROR or GL_DEBUG_SEVERITY_HIGH messages
//   abort      count, then abort() on the first one
#pragma once
#include <cstdint>

namespace rni::glvalidation {

using ProcLoader = void* (*)(const char* name, void* userData);

bool Enabled();  // RNI_GL_VALIDATION is 1 or abort; cheap, safe before any context exists

// Call with the new context current, before Impeller is handed the context.
// No-op when disabled. Returns false if enabled but the driver lacks KHR_debug.
bool Install(ProcLoader loader, void* userData);

// FP-05 test hooks (RNI_TEST_GL_BAD_BIND=1 binds texture name 0xDEAD on frame 2).
// Call once per presented frame on the thread that owns the GL context.
void OnFrame();

uint64_t ErrorCount();
void Finish();  // prints gl_validation_errors=N (once per call)

}  // namespace rni::glvalidation
