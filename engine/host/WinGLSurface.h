// WinGLSurface — the Windows peer of HeadlessSurface (ANGLE → D3D11 → GLES3).
//
// Same contract as HeadlessSurface so host/main.cpp can hold either behind one
// alias; see WinGLSurface.cpp for why Windows needs an entirely different
// context-acquisition path (and why it is GL and not Vulkan).
#pragma once

// WIN32_LEAN_AND_MEAN / NOMINMAX come from the MSVC-wide add_compile_definitions
// in engine/CMakeLists.txt — defining them here as well is a C4005 macro
// redefinition warning on every TU that includes this header.
#include <windows.h>

#include <cstdint>
#include <string>
#include <type_traits>
#include <vector>

#include <EGL/egl.h>
#include <EGL/eglext.h>
// ANGLE's platform-selection tokens (EGL_PLATFORM_ANGLE_ANGLE, the TYPE_*
// backends) are NOT in the Khronos eglext.h, and eglext.h does not include this.
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>

#include "host/Pixel.h"
#include "impeller.h"

namespace rni {

// Every entry point is a runtime-resolved pointer: ANGLE ships DLLs with no
// import libraries, so calling egl*/gl* directly compiles and then fails to
// link. See WinGLSurface.cpp.
struct WinEgl {
  EGLDisplay(EGLAPIENTRY* GetPlatformDisplayEXT)(EGLenum, void*, const EGLint*);
  EGLBoolean(EGLAPIENTRY* Initialize)(EGLDisplay, EGLint*, EGLint*);
  EGLBoolean(EGLAPIENTRY* ChooseConfig)(EGLDisplay, const EGLint*, EGLConfig*,
                                        EGLint, EGLint*);
  EGLSurface(EGLAPIENTRY* CreatePbufferSurface)(EGLDisplay, EGLConfig,
                                                const EGLint*);
  EGLBoolean(EGLAPIENTRY* BindAPI)(EGLenum);
  EGLContext(EGLAPIENTRY* CreateContext)(EGLDisplay, EGLConfig, EGLContext,
                                         const EGLint*);
  EGLBoolean(EGLAPIENTRY* MakeCurrent)(EGLDisplay, EGLSurface, EGLSurface,
                                       EGLContext);
  EGLint(EGLAPIENTRY* GetError)(void);
  const char*(EGLAPIENTRY* QueryString)(EGLDisplay, EGLint);
  __eglMustCastToProperFunctionPointerType(EGLAPIENTRY* GetProcAddress)(const char*);
};

struct WinGl {
  void(APIENTRY* GenTextures)(GLsizei, GLuint*);
  void(APIENTRY* BindTexture)(GLenum, GLuint);
  void(APIENTRY* TexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint,
                             GLenum, GLenum, const void*);
  void(APIENTRY* GenFramebuffers)(GLsizei, GLuint*);
  void(APIENTRY* BindFramebuffer)(GLenum, GLuint);
  void(APIENTRY* FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
  GLenum(APIENTRY* CheckFramebufferStatus)(GLenum);
  void(APIENTRY* ReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void*);
  GLenum(APIENTRY* GetError)(void);
  const GLubyte*(APIENTRY* GetString)(GLenum);
  void(APIENTRY* Finish)(void);
};

class WinGLSurface {
 public:
  ~WinGLSurface();

  bool init(int width, int height, std::string* error);

  ImpellerContext context() const { return context_; }
  ImpellerSurface surface() const { return surface_; }
  ImpellerTypographyContext typography() const { return typography_; }
  int width() const { return width_; }
  int height() const { return height_; }

  bool drawDisplayList(ImpellerDisplayList dl);
  // Reads the framebuffer back, ALREADY Y-FLIPPED into top-left order.
  bool readPixels(std::vector<Px>* out);

  // Kept as a static member so `Surface::writePpm(...)` compiles identically on
  // both platforms; the implementation is the shared one in Pixel.cpp.
  static bool writePpm(const std::string& path, const std::vector<Px>& px,
                       int width, int height) {
    return WritePpm(path, px, width, height);
  }

  const WinEgl& egl() const { return egl_; }
  void* glesModule() const { return glesModule_; }

 private:
  bool loadAngle(std::string* error);

  int width_{0};
  int height_{0};
  void* eglModule_{nullptr};
  void* glesModule_{nullptr};
  WinEgl egl_{};
  WinGl gl_{};
  const char* backend_{"none"};
  void* display_{nullptr};     // EGLDisplay
  void* pbuffer_{nullptr};     // EGLSurface (never drawn into; see .cpp)
  void* eglContext_{nullptr};  // EGLContext
  uint32_t texture_{0};
  uint32_t fbo_{0};
  ImpellerContext context_{nullptr};
  ImpellerSurface surface_{nullptr};
  ImpellerTypographyContext typography_{nullptr};
};

}  // namespace rni
