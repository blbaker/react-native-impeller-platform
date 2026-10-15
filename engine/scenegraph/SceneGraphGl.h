#pragma once
// GL entry points for the SceneGraph offscreen paths (ENG item 2 / 2b
// supersample, ENG-09/10 <world>). Include ONLY from SceneGraph.cpp, after
// every other header: on Windows the gl* names below become macros.
//
// Linux links libGLESv2 and darwin links ANGLE's dylibs, so the direct gl*
// calls resolve at link time there and this header is just <GLES3/gl3.h>.
//
// ⛔ WINDOWS: ANGLE ships libGLESv2.dll with NO IMPORT LIBRARY, and the GL
// headers declare every gl* as __declspec(dllimport). A direct call would fail
// to link. Each entry point the offscreen uses is therefore a pointer resolved
// from the libGLESv2.dll export table at first use (scenegraph/SceneGraphGlWin.cpp),
// and the macros keep every call site identical on all hosts. ANGLE keeps the
// current context in libGLESv2.dll, so these pointers act on the SAME context
// Impeller draws with (WinGLSurface headless, GLFW's EGL path windowed): there
// is exactly one libGLESv2.dll, beside the exe.
#include <GLES3/gl3.h>

#if defined(_WIN32)
namespace rni::scenegraph_gl {

struct Table {
  PFNGLBINDFRAMEBUFFERPROC BindFramebuffer = nullptr;
  PFNGLBINDRENDERBUFFERPROC BindRenderbuffer = nullptr;
  PFNGLBINDTEXTUREPROC BindTexture = nullptr;
  PFNGLCHECKFRAMEBUFFERSTATUSPROC CheckFramebufferStatus = nullptr;
  PFNGLDELETEFRAMEBUFFERSPROC DeleteFramebuffers = nullptr;
  PFNGLDELETERENDERBUFFERSPROC DeleteRenderbuffers = nullptr;
  PFNGLDELETETEXTURESPROC DeleteTextures = nullptr;
  PFNGLFINISHPROC Finish = nullptr;
  PFNGLFRAMEBUFFERRENDERBUFFERPROC FramebufferRenderbuffer = nullptr;
  PFNGLFRAMEBUFFERTEXTURE2DPROC FramebufferTexture2D = nullptr;
  PFNGLGENFRAMEBUFFERSPROC GenFramebuffers = nullptr;
  PFNGLGENRENDERBUFFERSPROC GenRenderbuffers = nullptr;
  PFNGLGENTEXTURESPROC GenTextures = nullptr;
  PFNGLGETINTEGERVPROC GetIntegerv = nullptr;
  PFNGLRENDERBUFFERSTORAGEPROC RenderbufferStorage = nullptr;
  PFNGLTEXIMAGE2DPROC TexImage2D = nullptr;
  PFNGLTEXPARAMETERIPROC TexParameteri = nullptr;
  PFNGLTEXSUBIMAGE2DPROC TexSubImage2D = nullptr;
  PFNGLVIEWPORTPROC Viewport = nullptr;
  // FP-17 IO upload fence
  PFNGLFENCESYNCPROC FenceSync = nullptr;
  PFNGLCLIENTWAITSYNCPROC ClientWaitSync = nullptr;
  PFNGLDELETESYNCPROC DeleteSync = nullptr;
  PFNGLFLUSHPROC Flush = nullptr;
};
extern Table gGl;

// Resolves the whole table once (thread-safe, cached). Returns false, and logs
// the first missing name once, if libGLESv2.dll is not loaded or lacks an
// export. Callers then skip the offscreen and paint in place (aliased, never
// blank), the same fallback as an incomplete FBO.
bool Load();

}  // namespace rni::scenegraph_gl

#define glBindFramebuffer ::rni::scenegraph_gl::gGl.BindFramebuffer
#define glBindRenderbuffer ::rni::scenegraph_gl::gGl.BindRenderbuffer
#define glBindTexture ::rni::scenegraph_gl::gGl.BindTexture
#define glCheckFramebufferStatus ::rni::scenegraph_gl::gGl.CheckFramebufferStatus
#define glDeleteFramebuffers ::rni::scenegraph_gl::gGl.DeleteFramebuffers
#define glDeleteRenderbuffers ::rni::scenegraph_gl::gGl.DeleteRenderbuffers
#define glDeleteTextures ::rni::scenegraph_gl::gGl.DeleteTextures
#define glFinish ::rni::scenegraph_gl::gGl.Finish
#define glFramebufferRenderbuffer ::rni::scenegraph_gl::gGl.FramebufferRenderbuffer
#define glFramebufferTexture2D ::rni::scenegraph_gl::gGl.FramebufferTexture2D
#define glGenFramebuffers ::rni::scenegraph_gl::gGl.GenFramebuffers
#define glGenRenderbuffers ::rni::scenegraph_gl::gGl.GenRenderbuffers
#define glGenTextures ::rni::scenegraph_gl::gGl.GenTextures
#define glGetIntegerv ::rni::scenegraph_gl::gGl.GetIntegerv
#define glRenderbufferStorage ::rni::scenegraph_gl::gGl.RenderbufferStorage
#define glTexImage2D ::rni::scenegraph_gl::gGl.TexImage2D
#define glTexParameteri ::rni::scenegraph_gl::gGl.TexParameteri
#define glTexSubImage2D ::rni::scenegraph_gl::gGl.TexSubImage2D
#define glViewport ::rni::scenegraph_gl::gGl.Viewport
#define glFenceSync ::rni::scenegraph_gl::gGl.FenceSync
#define glClientWaitSync ::rni::scenegraph_gl::gGl.ClientWaitSync
#define glDeleteSync ::rni::scenegraph_gl::gGl.DeleteSync
#define glFlush ::rni::scenegraph_gl::gGl.Flush

namespace rni::scenegraph_gl {
inline bool Ready() { return Load(); }
}  // namespace rni::scenegraph_gl
#else
namespace rni::scenegraph_gl {
inline bool Ready() { return true; }  // linked directly
}  // namespace rni::scenegraph_gl
#endif
