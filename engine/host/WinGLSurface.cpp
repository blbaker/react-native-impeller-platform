// WinGLSurface — ANGLE (EGL→D3D11) + GLES3 FBO wrapped as an Impeller surface.
//
// The Windows peer of HeadlessSurface. Same contract, same FBO dance, same
// Y-flip; only the GL CONTEXT ACQUISITION differs, and it differs in three ways
// that are each worth a comment because none of them is guessable from the
// Linux file:
//
//  1. ANGLE ships as libEGL.dll + libGLESv2.dll with NO IMPORT LIBRARIES (that
//     is how Chromium/Electron redistribute it). `#include <EGL/egl.h>` plus a
//     direct `eglInitialize(...)` compiles perfectly and dies at LINK with
//     `unresolved external symbol __imp_eglInitialize`. Every EGL *and* GL entry
//     point here is therefore resolved with LoadLibrary/GetProcAddress.
//  2. `EGL_PLATFORM_SURFACELESS_MESA` — the whole trick on Linux — is a MESA
//     extension. ANGLE does not implement it. Windows goes through
//     `EGL_PLATFORM_ANGLE_ANGLE` + `EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE` and a
//     real pbuffer surface instead.
//  3. Those ANGLE tokens are NOT in Khronos `eglext.h`; they live in
//     `EGL/eglext_angle.h`.
//
// Why GL at all on Windows, when impeller.dll exports ImpellerContextCreateVulkanNew:
// the SDK's only OFFSCREEN surface constructor is ImpellerSurfaceCreateWrappedFBONew,
// which takes a GL framebuffer (the only other one wraps a CAMetalDrawable). A
// Vulkan context has nothing to render into headlessly, and every pixel gate in
// this program is headless. GL is not a preference here, it is the only door.
#include "base/ContextFlags.h"
#include "base/GlLimits.h"
#include "base/GlValidation.h"
#include "fabric/ImageStore.h"
#include "host/WinGLSurface.h"

#include <cstdio>

namespace rni {

namespace {

// Impeller resolves every GL symbol it needs through this callback.
// libGLESv2's module export is tried FIRST and eglGetProcAddress second: EGL 1.4
// is only REQUIRED to return extension functions, so a null return for a core
// entry point like glGenFramebuffers is legal and would look like a broken
// driver.
WinGLSurface* g_active = nullptr;

void* ImpellerProcAddr(const char* name, void* user) {
  auto* self = static_cast<WinGLSurface*>(user);
  if (self->glesModule()) {
    if (void* p = (void*)::GetProcAddress((HMODULE)self->glesModule(), name)) {
      return p;
    }
  }
  return (void*)self->egl().GetProcAddress(name);
}

const char* EglErrStr(EGLint e) {
  switch (e) {
    case EGL_SUCCESS: return "EGL_SUCCESS";
    case EGL_NOT_INITIALIZED: return "EGL_NOT_INITIALIZED";
    case EGL_BAD_ACCESS: return "EGL_BAD_ACCESS";
    case EGL_BAD_ALLOC: return "EGL_BAD_ALLOC";
    case EGL_BAD_ATTRIBUTE: return "EGL_BAD_ATTRIBUTE";
    case EGL_BAD_CONFIG: return "EGL_BAD_CONFIG";
    case EGL_BAD_CONTEXT: return "EGL_BAD_CONTEXT";
    case EGL_BAD_DISPLAY: return "EGL_BAD_DISPLAY";
    case EGL_BAD_MATCH: return "EGL_BAD_MATCH";
    case EGL_BAD_PARAMETER: return "EGL_BAD_PARAMETER";
    case EGL_BAD_SURFACE: return "EGL_BAD_SURFACE";
    default: return "EGL_<other>";
  }
}

}  // namespace

WinGLSurface::~WinGLSurface() {
  if (typography_) ImpellerTypographyContextRelease(typography_);
  if (surface_) ImpellerSurfaceRelease(surface_);
  if (context_) ImpellerContextRelease(context_);
  if (g_active == this) g_active = nullptr;
}

bool WinGLSurface::loadAngle(std::string* error) {
  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };

  // Bare names, so the loader takes them from the executable's directory first
  // — which is where the packaged engine puts them. Windows has no rpath: an
  // ANGLE that is not beside the exe kills the process before main() with no
  // output at all.
  eglModule_ = ::LoadLibraryW(L"libEGL.dll");
  glesModule_ = ::LoadLibraryW(L"libGLESv2.dll");
  if (!eglModule_ || !glesModule_) {
    return fail("could not load ANGLE (libEGL.dll / libGLESv2.dll must sit beside the engine binary)");
  }

  auto E = [&](auto* slot, const char* name) {
    *slot = reinterpret_cast<std::remove_reference_t<decltype(*slot)>>(
        ::GetProcAddress((HMODULE)eglModule_, name));
    return *slot != nullptr;
  };
  auto G = [&](auto* slot, const char* name) {
    *slot = reinterpret_cast<std::remove_reference_t<decltype(*slot)>>(
        ::GetProcAddress((HMODULE)glesModule_, name));
    return *slot != nullptr;
  };

  if (!E(&egl_.GetPlatformDisplayEXT, "eglGetPlatformDisplayEXT") ||
      !E(&egl_.Initialize, "eglInitialize") ||
      !E(&egl_.ChooseConfig, "eglChooseConfig") ||
      !E(&egl_.CreatePbufferSurface, "eglCreatePbufferSurface") ||
      !E(&egl_.BindAPI, "eglBindAPI") ||
      !E(&egl_.CreateContext, "eglCreateContext") ||
      !E(&egl_.MakeCurrent, "eglMakeCurrent") ||
      !E(&egl_.GetError, "eglGetError") ||
      !E(&egl_.QueryString, "eglQueryString") ||
      !E(&egl_.GetProcAddress, "eglGetProcAddress")) {
    return fail("libEGL.dll is missing an expected export");
  }

  if (!G(&gl_.GenTextures, "glGenTextures") ||
      !G(&gl_.BindTexture, "glBindTexture") ||
      !G(&gl_.TexImage2D, "glTexImage2D") ||
      !G(&gl_.GenFramebuffers, "glGenFramebuffers") ||
      !G(&gl_.BindFramebuffer, "glBindFramebuffer") ||
      !G(&gl_.FramebufferTexture2D, "glFramebufferTexture2D") ||
      !G(&gl_.GenRenderbuffers, "glGenRenderbuffers") ||
      !G(&gl_.BindRenderbuffer, "glBindRenderbuffer") ||
      !G(&gl_.RenderbufferStorage, "glRenderbufferStorage") ||
      !G(&gl_.FramebufferRenderbuffer, "glFramebufferRenderbuffer") ||
      !G(&gl_.CheckFramebufferStatus, "glCheckFramebufferStatus") ||
      !G(&gl_.ReadPixels, "glReadPixels") ||
      !G(&gl_.GetError, "glGetError") ||
      !G(&gl_.GetString, "glGetString") ||
      !G(&gl_.Finish, "glFinish")) {
    return fail("libGLESv2.dll is missing an expected export");
  }
  return true;
}

bool WinGLSurface::init(int width, int height, std::string* error) {
  width_ = width;
  height_ = height;
  g_active = this;

  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };

  if (!loadAngle(error)) return false;

  // D3D11 first, then ANGLE's own default. The chosen backend is PRINTED below,
  // never inferred: a silent fallback renders correctly and identically, which
  // is exactly how a platform gets declared working on a path it never took.
  struct Attempt { const char* name; EGLint type; };
  const Attempt attempts[] = {
      {"D3D11", EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE},
      {"DEFAULT", EGL_PLATFORM_ANGLE_TYPE_DEFAULT_ANGLE},
  };

  EGLDisplay dpy = EGL_NO_DISPLAY;
  for (const auto& a : attempts) {
    const EGLint dpyAttrs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, a.type, EGL_NONE};
    EGLDisplay d = egl_.GetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE,
                                              EGL_DEFAULT_DISPLAY, dpyAttrs);
    if (d == EGL_NO_DISPLAY) continue;
    EGLint major = 0, minor = 0;
    if (!egl_.Initialize(d, &major, &minor)) continue;
    dpy = d;
    backend_ = a.name;
    break;
  }
  if (dpy == EGL_NO_DISPLAY) return fail("no ANGLE display could be initialised");
  display_ = dpy;

  const EGLint cfgAttrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                             EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                             EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                             EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg = nullptr;
  EGLint n = 0;
  if (!egl_.ChooseConfig(dpy, cfgAttrs, &cfg, 1, &n) || n != 1) {
    return fail("eglChooseConfig failed");
  }

  // Unlike Mesa's surfaceless path, ANGLE needs a real drawable to make a
  // context current. The pbuffer is never drawn into — all rendering goes to
  // the FBO below — it exists purely to satisfy eglMakeCurrent.
  const EGLint pbAttrs[] = {EGL_WIDTH, width_, EGL_HEIGHT, height_, EGL_NONE};
  EGLSurface pbuf = egl_.CreatePbufferSurface(dpy, cfg, pbAttrs);
  if (pbuf == EGL_NO_SURFACE) return fail("eglCreatePbufferSurface failed");
  pbuffer_ = pbuf;

  if (!egl_.BindAPI(EGL_OPENGL_ES_API)) return fail("eglBindAPI failed");
  const EGLint ctxAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
  EGLContext ctx = egl_.CreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxAttrs);
  if (ctx == EGL_NO_CONTEXT) return fail("eglCreateContext failed");
  if (!egl_.MakeCurrent(dpy, pbuf, pbuf, ctx)) {
    std::printf("rn-impeller: eglMakeCurrent failed (%s)\n",
                EglErrStr(egl_.GetError()));
    return fail("eglMakeCurrent failed");
  }
  eglContext_ = ctx;

  gl_.GenTextures(1, &texture_);
  gl_.BindTexture(GL_TEXTURE_2D, texture_);
  gl_.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width_, height_, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, nullptr);
  gl_.GenFramebuffers(1, &fbo_);
  gl_.BindFramebuffer(GL_FRAMEBUFFER, fbo_);
  gl_.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           texture_, 0);
  // SC-40: without a stencil attachment every clip (rounded clips, per-side
  // borders, image radius) and every concave fill is silently a no-op; same
  // packed depth-stencil HeadlessSurface attaches on linux/darwin.
  gl_.GenRenderbuffers(1, &depthStencil_);
  gl_.BindRenderbuffer(GL_RENDERBUFFER, depthStencil_);
  gl_.RenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, width_, height_);
  gl_.FramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER,
                              depthStencil_);
  gl_.FramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER,
                              depthStencil_);
  if (gl_.CheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
    return fail("FBO incomplete");
  }

  rni::glvalidation::Install(&ImpellerProcAddr, this);  // FP-05
  rni::image::SetMaxTextureSize(rni::gllimits::MaxTextureSize(&ImpellerProcAddr, this));  // FP-16
  rni::contextflags::ApplyBeforeCreate();  // FP-22
  context_ = ImpellerContextCreateOpenGLESNew(IMPELLER_VERSION, &ImpellerProcAddr, this);
  rni::contextflags::Report(context_);
  if (!context_) return fail("ImpellerContextCreateOpenGLESNew returned null");
  ImpellerISize size = {width_, height_};
  surface_ = ImpellerSurfaceCreateWrappedFBONew(
      context_, fbo_, kImpellerPixelFormatRGBA8888, &size);
  if (!surface_) return fail("ImpellerSurfaceCreateWrappedFBONew returned null");

  typography_ = ImpellerTypographyContextNew();
  if (!typography_) return fail("ImpellerTypographyContextNew returned null");

  // Say the backend's own name, unconditionally. Same rule as the Linux
  // GL_RENDERER line: whenever a fallback exists, assume you are on it until a
  // log line says otherwise.
  std::printf("rn-impeller: GL_RENDERER=%s\n", (const char*)gl_.GetString(GL_RENDERER));
  std::printf("rn-impeller: angle_backend=%s egl_vendor=%s\n", backend_,
              egl_.QueryString(dpy, EGL_VENDOR));
  std::fflush(stdout);
  return true;
}

bool WinGLSurface::drawDisplayList(ImpellerDisplayList dl) {
  if (!ImpellerSurfaceDrawDisplayList(surface_, dl)) return false;
  gl_.Finish();
  return true;
}

bool WinGLSurface::readPixels(std::vector<Px>* out) {
  std::vector<Px> raw((size_t)width_ * height_);
  gl_.BindFramebuffer(GL_FRAMEBUFFER, fbo_);
  gl_.ReadPixels(0, 0, width_, height_, GL_RGBA, GL_UNSIGNED_BYTE, raw.data());
  if (gl_.GetError() != GL_NO_ERROR) return false;
  out->resize(raw.size());
  // glReadPixels is bottom-left origin, Impeller draws top-left. Identical to
  // the Linux path — without the flip every probe reads the wrong row and the
  // renderer gets blamed for a correct frame.
  for (int y = 0; y < height_; ++y) {
    for (int x = 0; x < width_; ++x) {
      (*out)[(size_t)y * width_ + x] = raw[(size_t)(height_ - 1 - y) * width_ + x];
    }
  }
  return true;
}

}  // namespace rni
