// P5-A spike: prove Impeller can render HEADLESS on Windows.
//
// The whole Windows port rests on one question this file answers with pixels:
// the Impeller standalone SDK's ONLY offscreen surface constructor is
// `ImpellerSurfaceCreateWrappedFBONew` (the Metal one needs a CAMetalDrawable,
// and there is no Vulkan/D3D offscreen constructor at all), so Windows headless
// rendering REQUIRES a GLES3 context. Windows has no system EGL, so that means
// ANGLE. If ANGLE cannot drive Impeller here, P5 is a different phase.
//
// Deliberately standalone, like the P0 spike: no ReactCommon, no Hermes, no
// CMake package. One translation unit, MSVC, run it, look at the bytes.
//
// ANGLE is loaded DYNAMICALLY (LoadLibrary/GetProcAddress) rather than linked,
// so the spike needs no import libraries and no ANGLE SDK on the box — only the
// two DLLs beside the exe. That is also how the engine will consume it: the
// shipped package cannot assume an ANGLE dev kit on a consumer's machine.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include <EGL/egl.h>
#include <EGL/eglext.h>
// ANGLE's platform-selection tokens (EGL_PLATFORM_ANGLE_ANGLE and the
// TYPE_* backends) are NOT in the Khronos eglext.h — they live in this
// vendor header, which eglext.h does not pull in. Without it the tokens are
// undeclared identifiers and the whole attempt table fails to parse.
#include <EGL/eglext_angle.h>
// GL types (GLuint/GLenum), enums (GL_FRAMEBUFFER, ...) and the calling
// convention macro all come from here. The core PROTOTYPES it also declares are
// never referenced — every GL call in this file goes through a pointer resolved
// from libGLESv2.dll at runtime — so nothing links against an ANGLE import lib.
#include <GLES3/gl3.h>

#include "impeller.h"

namespace {

// ---- EGL entry points, also resolved at runtime -----------------------------
// ⛔ These are resolved dynamically for a REASON, not for symmetry with GL.
// ANGLE ships as libEGL.dll + libGLESv2.dll with NO import libraries (that is
// how Chrome/Edge/VS Code redistribute it), so `#include <EGL/egl.h>` plus a
// direct `eglInitialize(...)` call compiles fine and then dies at link time
// with nine `unresolved external symbol __imp_egl*`. Windows has no rpath and
// no .so-with-embedded-deps equivalent: whatever the engine ships, it must
// LoadLibrary. Doing that here keeps the spike honest about what the real
// engine will have to do.
typedef EGLDisplay(EGLAPIENTRY* PFN_eglGetPlatformDisplayEXT)(EGLenum, void*,
                                                              const EGLint*);
typedef EGLBoolean(EGLAPIENTRY* PFN_eglInitialize)(EGLDisplay, EGLint*, EGLint*);
typedef EGLBoolean(EGLAPIENTRY* PFN_eglChooseConfig)(EGLDisplay, const EGLint*,
                                                     EGLConfig*, EGLint, EGLint*);
typedef EGLSurface(EGLAPIENTRY* PFN_eglCreatePbufferSurface)(EGLDisplay, EGLConfig,
                                                             const EGLint*);
typedef EGLBoolean(EGLAPIENTRY* PFN_eglBindAPI)(EGLenum);
typedef EGLContext(EGLAPIENTRY* PFN_eglCreateContext)(EGLDisplay, EGLConfig,
                                                      EGLContext, const EGLint*);
typedef EGLBoolean(EGLAPIENTRY* PFN_eglMakeCurrent)(EGLDisplay, EGLSurface,
                                                    EGLSurface, EGLContext);
typedef EGLint(EGLAPIENTRY* PFN_eglGetError)(void);
typedef const char*(EGLAPIENTRY* PFN_eglQueryString)(EGLDisplay, EGLint);
typedef __eglMustCastToProperFunctionPointerType(EGLAPIENTRY* PFN_eglGetProcAddress)(
    const char*);

struct Egl {
  PFN_eglGetPlatformDisplayEXT GetPlatformDisplayEXT;
  PFN_eglInitialize Initialize;
  PFN_eglChooseConfig ChooseConfig;
  PFN_eglCreatePbufferSurface CreatePbufferSurface;
  PFN_eglBindAPI BindAPI;
  PFN_eglCreateContext CreateContext;
  PFN_eglMakeCurrent MakeCurrent;
  PFN_eglGetError GetError;
  PFN_eglQueryString QueryString;
  PFN_eglGetProcAddress GetProcAddress;
};

// ---- GL entry points, resolved at runtime -----------------------------------
// Only the handful the FBO dance needs. Resolved from libGLESv2.dll directly
// rather than through eglGetProcAddress: EGL 1.4's eglGetProcAddress is only
// REQUIRED to return extension functions, and returning null for a core
// function like glGenFramebuffers is legal. Impeller's own callback (below)
// tries both, for the same reason.
typedef void(APIENTRY* PFN_glGenTextures)(GLsizei, GLuint*);
typedef void(APIENTRY* PFN_glBindTexture)(GLenum, GLuint);
typedef void(APIENTRY* PFN_glTexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei,
                                         GLint, GLenum, GLenum, const void*);
typedef void(APIENTRY* PFN_glGenFramebuffers)(GLsizei, GLuint*);
typedef void(APIENTRY* PFN_glBindFramebuffer)(GLenum, GLuint);
typedef void(APIENTRY* PFN_glFramebufferTexture2D)(GLenum, GLenum, GLenum,
                                                   GLuint, GLint);
typedef GLenum(APIENTRY* PFN_glCheckFramebufferStatus)(GLenum);
typedef void(APIENTRY* PFN_glReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum,
                                         GLenum, void*);
typedef GLenum(APIENTRY* PFN_glGetError)(void);
typedef const GLubyte*(APIENTRY* PFN_glGetString)(GLenum);
typedef void(APIENTRY* PFN_glFinish)(void);

struct Gl {
  PFN_glGenTextures GenTextures;
  PFN_glBindTexture BindTexture;
  PFN_glTexImage2D TexImage2D;
  PFN_glGenFramebuffers GenFramebuffers;
  PFN_glBindFramebuffer BindFramebuffer;
  PFN_glFramebufferTexture2D FramebufferTexture2D;
  PFN_glCheckFramebufferStatus CheckFramebufferStatus;
  PFN_glReadPixels ReadPixels;
  PFN_glGetError GetError;
  PFN_glGetString GetString;
  PFN_glFinish Finish;
};

HMODULE g_egl = nullptr;
HMODULE g_gles = nullptr;
Gl g_gl = {};
Egl g_egl_fn = {};

// Impeller resolves every GL symbol it needs through this. Trying the GLESv2
// module FIRST and eglGetProcAddress second is deliberate: on ANGLE the module
// export is the reliable path for core functions.
void* ImpellerProcAddr(const char* name, void*) {
  if (g_gles) {
    if (void* p = (void*)::GetProcAddress(g_gles, name)) {
      return p;
    }
  }
  return (void*)g_egl_fn.GetProcAddress(name);
}

template <typename T>
bool Load(T* out, const char* name) {
  *out = (T)::GetProcAddress(g_gles, name);
  if (!*out) {
    std::printf("SPIKE_FAIL missing GL export: %s\n", name);
    return false;
  }
  return true;
}

template <typename T>
bool LoadEgl(T* out, const char* name) {
  *out = (T)::GetProcAddress(g_egl, name);
  if (!*out) {
    std::printf("SPIKE_FAIL missing EGL export: %s\n", name);
    return false;
  }
  return true;
}

const char* EglErrStr(EGLint e) {
  switch (e) {
    case EGL_SUCCESS: return "EGL_SUCCESS";
    case EGL_NOT_INITIALIZED: return "EGL_NOT_INITIALIZED";
    case EGL_BAD_ACCESS: return "EGL_BAD_ACCESS";
    case EGL_BAD_ALLOC: return "EGL_BAD_ALLOC";
    case EGL_BAD_ATTRIBUTE: return "EGL_BAD_ATTRIBUTE";
    case EGL_BAD_CONFIG: return "EGL_BAD_CONFIG";
    case EGL_BAD_DISPLAY: return "EGL_BAD_DISPLAY";
    case EGL_BAD_MATCH: return "EGL_BAD_MATCH";
    case EGL_BAD_PARAMETER: return "EGL_BAD_PARAMETER";
    default: return "EGL_<other>";
  }
}

}  // namespace

int main(int argc, char** argv) {
  const int kW = 200;
  const int kH = 120;

  // ---- 1. Load ANGLE ---------------------------------------------------------
  g_egl = ::LoadLibraryW(L"libEGL.dll");
  g_gles = ::LoadLibraryW(L"libGLESv2.dll");
  if (!g_egl || !g_gles) {
    std::printf("SPIKE_FAIL could not load ANGLE (libEGL=%p libGLESv2=%p)\n",
                (void*)g_egl, (void*)g_gles);
    return 1;
  }

  if (!Load(&g_gl.GenTextures, "glGenTextures") ||
      !Load(&g_gl.BindTexture, "glBindTexture") ||
      !Load(&g_gl.TexImage2D, "glTexImage2D") ||
      !Load(&g_gl.GenFramebuffers, "glGenFramebuffers") ||
      !Load(&g_gl.BindFramebuffer, "glBindFramebuffer") ||
      !Load(&g_gl.FramebufferTexture2D, "glFramebufferTexture2D") ||
      !Load(&g_gl.CheckFramebufferStatus, "glCheckFramebufferStatus") ||
      !Load(&g_gl.ReadPixels, "glReadPixels") ||
      !Load(&g_gl.GetError, "glGetError") ||
      !Load(&g_gl.GetString, "glGetString") ||
      !Load(&g_gl.Finish, "glFinish")) {
    return 1;
  }

  if (!LoadEgl(&g_egl_fn.GetPlatformDisplayEXT, "eglGetPlatformDisplayEXT") ||
      !LoadEgl(&g_egl_fn.Initialize, "eglInitialize") ||
      !LoadEgl(&g_egl_fn.ChooseConfig, "eglChooseConfig") ||
      !LoadEgl(&g_egl_fn.CreatePbufferSurface, "eglCreatePbufferSurface") ||
      !LoadEgl(&g_egl_fn.BindAPI, "eglBindAPI") ||
      !LoadEgl(&g_egl_fn.CreateContext, "eglCreateContext") ||
      !LoadEgl(&g_egl_fn.MakeCurrent, "eglMakeCurrent") ||
      !LoadEgl(&g_egl_fn.GetError, "eglGetError") ||
      !LoadEgl(&g_egl_fn.QueryString, "eglQueryString") ||
      !LoadEgl(&g_egl_fn.GetProcAddress, "eglGetProcAddress")) {
    return 1;
  }

  // ---- 2. Display ------------------------------------------------------------
  // NOT the Linux path. `EGL_PLATFORM_SURFACELESS_MESA` is a Mesa extension
  // ANGLE does not implement, so the engine's Linux trick does not port; ANGLE
  // wants EGL_PLATFORM_ANGLE_ANGLE and a real (pbuffer) surface.
  auto getPlatformDisplay = g_egl_fn.GetPlatformDisplayEXT;
  if (!getPlatformDisplay) {
    std::printf("SPIKE_FAIL eglGetPlatformDisplayEXT unavailable\n");
    return 1;
  }

  // Try D3D11 first, then whatever ANGLE picks by default. Printing which one
  // won matters: a silent fallback to a different backend is exactly the class
  // of mistake that gets a platform declared working on a path it never ran.
  struct Attempt {
    const char* name;
    EGLint type;
  };
  const Attempt attempts[] = {
      {"D3D11", EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE},
      {"DEFAULT", EGL_PLATFORM_ANGLE_TYPE_DEFAULT_ANGLE},
  };

  EGLDisplay dpy = EGL_NO_DISPLAY;
  const char* chosen = nullptr;
  for (const auto& a : attempts) {
    const EGLint dpyAttrs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, a.type, EGL_NONE};
    EGLDisplay d = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE,
                                      EGL_DEFAULT_DISPLAY, dpyAttrs);
    if (d == EGL_NO_DISPLAY) {
      std::printf("[egl] platform %s: no display (%s)\n", a.name,
                  EglErrStr(g_egl_fn.GetError()));
      continue;
    }
    EGLint major = 0, minor = 0;
    if (!g_egl_fn.Initialize(d, &major, &minor)) {
      std::printf("[egl] platform %s: eglInitialize failed (%s)\n", a.name,
                  EglErrStr(g_egl_fn.GetError()));
      continue;
    }
    std::printf("[egl] platform %s: EGL %d.%d\n", a.name, major, minor);
    dpy = d;
    chosen = a.name;
    break;
  }
  if (dpy == EGL_NO_DISPLAY) {
    std::printf("SPIKE_FAIL no ANGLE display could be initialised\n");
    return 1;
  }

  std::printf("[egl] vendor=%s\n", g_egl_fn.QueryString(dpy, EGL_VENDOR));
  std::printf("[egl] version=%s\n", g_egl_fn.QueryString(dpy, EGL_VERSION));

  // ---- 3. Config + pbuffer ---------------------------------------------------
  const EGLint cfgAttrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                             EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                             EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                             EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg = nullptr;
  EGLint n = 0;
  if (!g_egl_fn.ChooseConfig(dpy, cfgAttrs, &cfg, 1, &n) || n != 1) {
    std::printf("SPIKE_FAIL eglChooseConfig (%s, n=%d)\n",
                EglErrStr(g_egl_fn.GetError()), n);
    return 1;
  }

  const EGLint pbAttrs[] = {EGL_WIDTH, kW, EGL_HEIGHT, kH, EGL_NONE};
  EGLSurface pbuf = g_egl_fn.CreatePbufferSurface(dpy, cfg, pbAttrs);
  if (pbuf == EGL_NO_SURFACE) {
    std::printf("SPIKE_FAIL eglCreatePbufferSurface (%s)\n",
                EglErrStr(g_egl_fn.GetError()));
    return 1;
  }

  if (!g_egl_fn.BindAPI(EGL_OPENGL_ES_API)) {
    std::printf("SPIKE_FAIL eglBindAPI (%s)\n", EglErrStr(g_egl_fn.GetError()));
    return 1;
  }
  const EGLint ctxAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
  EGLContext ctx = g_egl_fn.CreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxAttrs);
  if (ctx == EGL_NO_CONTEXT) {
    std::printf("SPIKE_FAIL eglCreateContext (%s)\n", EglErrStr(g_egl_fn.GetError()));
    return 1;
  }
  if (!g_egl_fn.MakeCurrent(dpy, pbuf, pbuf, ctx)) {
    std::printf("SPIKE_FAIL eglMakeCurrent (%s)\n", EglErrStr(g_egl_fn.GetError()));
    return 1;
  }

  // Say the backend's own name, unconditionally. A silent fallback that renders
  // correctly is how a platform gets validated on a path it never took.
  std::printf("[gl] platform=%s renderer=%s\n", chosen,
              (const char*)g_gl.GetString(GL_RENDERER));
  std::printf("[gl] version=%s\n", (const char*)g_gl.GetString(GL_VERSION));

  // ---- 4. FBO ----------------------------------------------------------------
  GLuint tex = 0, fbo = 0;
  g_gl.GenTextures(1, &tex);
  g_gl.BindTexture(GL_TEXTURE_2D, tex);
  g_gl.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, kW, kH, 0, GL_RGBA,
                  GL_UNSIGNED_BYTE, nullptr);
  g_gl.GenFramebuffers(1, &fbo);
  g_gl.BindFramebuffer(GL_FRAMEBUFFER, fbo);
  g_gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                            tex, 0);
  if (g_gl.CheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
    std::printf("SPIKE_FAIL FBO incomplete\n");
    return 1;
  }

  // ---- 5. Impeller -----------------------------------------------------------
  std::printf("[impeller] header=%u library=%u\n", IMPELLER_VERSION,
              ImpellerGetVersion());
  ImpellerContext ictx =
      ImpellerContextCreateOpenGLESNew(IMPELLER_VERSION, &ImpellerProcAddr, nullptr);
  if (!ictx) {
    std::printf("SPIKE_FAIL ImpellerContextCreateOpenGLESNew returned null\n");
    return 1;
  }
  ImpellerISize size = {kW, kH};
  ImpellerSurface isurf = ImpellerSurfaceCreateWrappedFBONew(
      ictx, fbo, kImpellerPixelFormatRGBA8888, &size);
  if (!isurf) {
    std::printf("SPIKE_FAIL ImpellerSurfaceCreateWrappedFBONew returned null\n");
    return 1;
  }

  // Draw a red rect on a known-empty surface. Two probes, one positive and one
  // negative, so a renderer that floods the whole surface fails just as loudly
  // as one that draws nothing.
  ImpellerDisplayListBuilder builder = ImpellerDisplayListBuilderNew(nullptr);
  ImpellerPaint paint = ImpellerPaintNew();
  ImpellerColor red = {1.0f, 0.0f, 0.0f, 1.0f};
  ImpellerPaintSetColor(paint, &red);
  ImpellerRect rect = {20, 20, 60, 40};  // x, y, w, h
  ImpellerDisplayListBuilderDrawRect(builder, &rect, paint);
  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(builder);
  if (!dl) {
    std::printf("SPIKE_FAIL display list creation returned null\n");
    return 1;
  }
  if (!ImpellerSurfaceDrawDisplayList(isurf, dl)) {
    std::printf("SPIKE_FAIL ImpellerSurfaceDrawDisplayList failed\n");
    return 1;
  }
  g_gl.Finish();

  // ---- 6. Read back ----------------------------------------------------------
  struct Px { unsigned char r, g, b, a; };
  std::vector<Px> raw((size_t)kW * kH);
  g_gl.BindFramebuffer(GL_FRAMEBUFFER, fbo);
  g_gl.ReadPixels(0, 0, kW, kH, GL_RGBA, GL_UNSIGNED_BYTE, raw.data());
  if (g_gl.GetError() != GL_NO_ERROR) {
    std::printf("SPIKE_FAIL glReadPixels error\n");
    return 1;
  }
  // glReadPixels is bottom-left origin, Impeller draws top-left. Flip, or every
  // probe reads the wrong row and blames the renderer.
  auto at = [&](int x, int y) -> Px {
    return raw[(size_t)(kH - 1 - y) * kW + x];
  };

  Px inside = at(50, 40);    // centre of the rect
  Px outside = at(150, 100); // far corner, must stay empty
  std::printf("[probe] inside(50,40)   = %u,%u,%u,%u\n", inside.r, inside.g,
              inside.b, inside.a);
  std::printf("[probe] outside(150,100)= %u,%u,%u,%u\n", outside.r, outside.g,
              outside.b, outside.a);

  bool ok = inside.r > 200 && inside.g < 60 && inside.b < 60 &&
            outside.r < 60 && outside.g < 60 && outside.b < 60;

  // Distinct-colour floor: a surface painted one flat colour cannot pass by
  // luck, which is the failure the P3 gates were rebuilt around.
  int distinct = 0;
  {
    std::vector<uint32_t> seen;
    for (const auto& p : raw) {
      uint32_t k = (uint32_t)p.r << 24 | (uint32_t)p.g << 16 |
                   (uint32_t)p.b << 8 | p.a;
      bool found = false;
      for (uint32_t s : seen) {
        if (s == k) { found = true; break; }
      }
      if (!found && seen.size() < 64) seen.push_back(k);
    }
    distinct = (int)seen.size();
  }
  std::printf("[probe] distinct_colours=%d\n", distinct);
  if (distinct < 2) ok = false;

  // Optional PPM dump so the frame can be looked at once, per the bring-up rule
  // that a pixel probe cannot tell you the image is sane.
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--ppm") == 0 && i + 1 < argc) {
      FILE* f = nullptr;
      if (fopen_s(&f, argv[i + 1], "wb") == 0 && f) {
        std::fprintf(f, "P6\n%d %d\n255\n", kW, kH);
        for (int y = 0; y < kH; ++y) {
          for (int x = 0; x < kW; ++x) {
            Px p = at(x, y);
            std::fwrite(&p, 1, 3, f);
          }
        }
        std::fclose(f);
        std::printf("[ppm] wrote %s\n", argv[i + 1]);
      }
    }
  }

  ImpellerDisplayListRelease(dl);
  ImpellerPaintRelease(paint);
  ImpellerDisplayListBuilderRelease(builder);
  ImpellerSurfaceRelease(isurf);
  ImpellerContextRelease(ictx);

  std::printf(ok ? "SPIKE_PASS impeller rendered headless on windows via ANGLE/%s\n"
                 : "SPIKE_FAIL pixel probes did not match\n",
              chosen);
  return ok ? 0 : 1;
}
