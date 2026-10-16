// Windows only: resolves the SceneGraph offscreen's GL entry points from
// ANGLE's libGLESv2.dll (see SceneGraphGl.h for why they cannot be linked).
// Kept out of SceneGraph.cpp so <windows.h> never reaches it.
#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <cstdio>
#include <mutex>

#include "scenegraph/SceneGraphGl.h"

namespace rni::scenegraph_gl {

Table gGl;

namespace {

template <typename T>
bool Resolve(HMODULE m, T* slot, const char* name, const char** firstMissing) {
  *slot = reinterpret_cast<T>(::GetProcAddress(m, name));
  if (!*slot && !*firstMissing) *firstMissing = name;
  return *slot != nullptr;
}

bool LoadOnce() {
  // GetModuleHandle, not LoadLibrary: the surface (WinGLSurface's LoadLibraryW,
  // or GLFW's EGL loader) has already mapped the one libGLESv2.dll whose
  // context is current. Taking no reference means this never pins or loads a
  // second copy.
  HMODULE m = ::GetModuleHandleW(L"libGLESv2.dll");
  if (!m) {
    fprintf(stderr,
            "rn-impeller: supersample_gl=0 (libGLESv2.dll not loaded); offscreen off, "
            "painting in place\n");
    return false;
  }
  const char* missing = nullptr;
  bool ok = true;
  ok &= Resolve(m, &gGl.BindFramebuffer, "glBindFramebuffer", &missing);
  ok &= Resolve(m, &gGl.BindRenderbuffer, "glBindRenderbuffer", &missing);
  ok &= Resolve(m, &gGl.BindTexture, "glBindTexture", &missing);
  ok &= Resolve(m, &gGl.CheckFramebufferStatus, "glCheckFramebufferStatus", &missing);
  ok &= Resolve(m, &gGl.DeleteFramebuffers, "glDeleteFramebuffers", &missing);
  ok &= Resolve(m, &gGl.DeleteRenderbuffers, "glDeleteRenderbuffers", &missing);
  ok &= Resolve(m, &gGl.DeleteTextures, "glDeleteTextures", &missing);
  ok &= Resolve(m, &gGl.Finish, "glFinish", &missing);
  ok &= Resolve(m, &gGl.FramebufferRenderbuffer, "glFramebufferRenderbuffer", &missing);
  ok &= Resolve(m, &gGl.FramebufferTexture2D, "glFramebufferTexture2D", &missing);
  ok &= Resolve(m, &gGl.GenFramebuffers, "glGenFramebuffers", &missing);
  ok &= Resolve(m, &gGl.GenRenderbuffers, "glGenRenderbuffers", &missing);
  ok &= Resolve(m, &gGl.GenTextures, "glGenTextures", &missing);
  ok &= Resolve(m, &gGl.GetIntegerv, "glGetIntegerv", &missing);
  ok &= Resolve(m, &gGl.RenderbufferStorage, "glRenderbufferStorage", &missing);
  ok &= Resolve(m, &gGl.TexImage2D, "glTexImage2D", &missing);
  ok &= Resolve(m, &gGl.TexParameteri, "glTexParameteri", &missing);
  ok &= Resolve(m, &gGl.TexSubImage2D, "glTexSubImage2D", &missing);
  ok &= Resolve(m, &gGl.Viewport, "glViewport", &missing);
  ok &= Resolve(m, &gGl.FenceSync, "glFenceSync", &missing);
  ok &= Resolve(m, &gGl.ClientWaitSync, "glClientWaitSync", &missing);
  ok &= Resolve(m, &gGl.DeleteSync, "glDeleteSync", &missing);
  ok &= Resolve(m, &gGl.Flush, "glFlush", &missing);
  if (!ok) {
    fprintf(stderr,
            "rn-impeller: supersample_gl=0 (%s unresolved in libGLESv2.dll); offscreen off, "
            "painting in place\n",
            missing);
    return false;
  }
  printf("rn-impeller: supersample_gl=1 (libGLESv2.dll exports)\n");
  fflush(stdout);
  return true;
}

}  // namespace

bool Load() {
  static std::once_flag once;
  static bool ok = false;
  std::call_once(once, [] { ok = LoadOnce(); });
  return ok;
}

}  // namespace rni::scenegraph_gl
#endif  // _WIN32
