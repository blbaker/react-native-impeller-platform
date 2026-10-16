// FP-32: the EGL half of context-loss recovery (see ContextLoss.h).
// Windows (ANGLE through GLFW's loader table) has no implementation yet:
// Supported() is false there and the test hook only logs.
#pragma once

#include <string>

namespace rni::ctxlossgl {

struct EglWindow {
  void* display = nullptr;  // EGLDisplay
  void* surface = nullptr;  // EGLSurface (the window's)
  void* context = nullptr;  // EGLContext, replaced by Recreate
};

bool Supported();
// Raster thread, `w.context` current. Makes nothing current, destroys the old
// context and creates a new one with the same config, client API and version
// (robust + LOSE_CONTEXT_ON_RESET when EGL offers it), current on w.surface.
bool Recreate(EglWindow& w, std::string* why);
// eglSwapBuffers; *lost = the swap failed with EGL_CONTEXT_LOST.
void Swap(const EglWindow& w, bool* lost);
// GL_KHR_robustness / EXT_robustness reset status of the current context:
// 0 = GL_NO_ERROR (or no robustness entry point), else the GL enum.
unsigned ResetStatus();
const char* ResetReason(unsigned status);
// Prints `context_robustness strategy=lose|none`: what the last Recreate got.
void ReportRobustness(const char* when);

}  // namespace rni::ctxlossgl
