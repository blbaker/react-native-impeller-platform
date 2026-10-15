// FP-14: RECORD runs with no GL context and makes no GL call.
//
// Flutter's UI thread has no GL context at all (the raster and IO threads own
// the onscreen and resource contexts, shell/gpu/gpu_surface_gl_impeller.cc);
// headless RECORD still shares its thread with RASTER (and FP-15's windowed
// raster thread owns the context outright), so this is how a gate proves the
// split is real:
//   RNI_ASSERT_NO_GL_IN_RECORD=1  the host releases its context around every
//     RECORD (surface hooks) and aborts if one is still current inside it
//     (eglGetCurrentContext() on EGL hosts).
//   rni_gl_shim_thread_calls      when an LD_PRELOAD GL shim exports it
//     (tools/lib/gl-count-shim), the GL calls this thread made inside RECORD
//     and inside RASTER are counted from it.
// Every run prints `record_gl calls= raster_calls= frames= shim= assert=
// released= starved= uploads= offscreens= jobs_failed=` at exit.
#pragma once

#include <cstdint>
#include <functional>

namespace rni::recordgl {

struct ContextHooks {
  std::function<bool()> release;    // make no context current
  std::function<bool()> acquire;    // make the surface's context current again
  std::function<bool()> isCurrent;  // a GL context is current on this thread
};
void SetContextHooks(ContextHooks hooks);  // surfaces, after init; {} clears
bool AssertMode();

// Brackets one RECORD (RecordFrame).
class RecordScope {
 public:
  RecordScope();
  ~RecordScope();
  RecordScope(const RecordScope&) = delete;
  RecordScope& operator=(const RecordScope&) = delete;

 private:
  uint64_t start_ = 0;
  bool released_ = false;
};

// Brackets one RASTER's GL work (proves the shim sees this thread's calls).
class RasterScope {
 public:
  RasterScope();
  ~RasterScope();

 private:
  uint64_t start_ = 0;
};

void NoteStarved(uint64_t starved);
void PrintSummary();

}  // namespace rni::recordgl
