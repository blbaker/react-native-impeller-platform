#include <cstdio>
#include <cmath>
#include <chrono>
#include "base/ContextFlags.h"
#include "base/GlLimits.h"
#include "base/GlValidation.h"
#include "fabric/ImageStore.h"
#include "host/GlfwSurface.h"

#if defined(_WIN32)
// Windows: keep GLFW from pulling in <GL/gl.h> (opengl32's GL 1.1). The
// window's context is ANGLE GLES3 through GLFW's EGL path, declared by the
// vendored Khronos gl3.h below.
#define GLFW_INCLUDE_NONE
#endif
#include <GLFW/glfw3.h>
#include <GLES3/gl3.h>

#include "host/PointScale.h"
#include "scenegraph/CursorKinds.h"

#if defined(__APPLE__)
// ⛔ macOS REACHES THE WINDOW THROUGH ANGLE, NOT THROUGH SYSTEM EGL.
// Same reason HeadlessSurface has an APPLE branch: Apple ships a frozen
// desktop GL 2.1 compatibility profile and NO EGL and NO GLES at all. The
// EGL_PLATFORM_ANGLE_* tokens live only in ANGLE's own extension header, which
// is vendored beside the Khronos ones (engine/third_party/khronos).
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#endif

#include <cstdio>
#include <cstdlib>
#include <string>
#include <unordered_map>

#if defined(_WIN32)
// ANGLE ships no import library, so on Windows nothing in this file may call
// gl* by name. Linux links libGLESv2 and darwin links ANGLE's dylibs, so the
// direct calls below resolve at link time there. On Windows libGLESv2.dll is
// only loaded at run time (by GLFW's EGL path), so each GL entry point this
// file uses is fetched through glfwGetProcAddress once the context is current.
// The macros keep every call site identical on all hosts.
namespace {
struct WinGl {
  PFNGLGETSTRINGPROC GetString = nullptr;
  PFNGLGETINTEGERVPROC GetIntegerv = nullptr;
  PFNGLVIEWPORTPROC Viewport = nullptr;
  PFNGLFINISHPROC Finish = nullptr;
  PFNGLBINDFRAMEBUFFERPROC BindFramebuffer = nullptr;
  PFNGLREADPIXELSPROC ReadPixels = nullptr;
  PFNGLGETERRORPROC GetError = nullptr;
};
WinGl gWinGl;

template <typename T>
bool LoadGlEntry(T* slot, const char* name) {
  *slot = reinterpret_cast<T>(glfwGetProcAddress(name));
  if (!*slot) fprintf(stderr, "rn-impeller: FATAL: %s unresolved\n", name);
  return *slot != nullptr;
}

bool LoadWinGl() {
  bool ok = true;
  ok &= LoadGlEntry(&gWinGl.GetString, "glGetString");
  ok &= LoadGlEntry(&gWinGl.GetIntegerv, "glGetIntegerv");
  ok &= LoadGlEntry(&gWinGl.Viewport, "glViewport");
  ok &= LoadGlEntry(&gWinGl.Finish, "glFinish");
  ok &= LoadGlEntry(&gWinGl.BindFramebuffer, "glBindFramebuffer");
  ok &= LoadGlEntry(&gWinGl.ReadPixels, "glReadPixels");
  ok &= LoadGlEntry(&gWinGl.GetError, "glGetError");
  return ok;
}
}  // namespace
#define glGetString gWinGl.GetString
#define glGetIntegerv gWinGl.GetIntegerv
#define glViewport gWinGl.Viewport
#define glFinish gWinGl.Finish
#define glBindFramebuffer gWinGl.BindFramebuffer
#define glReadPixels gWinGl.ReadPixels
#define glGetError gWinGl.GetError
#endif

namespace rni {

#if defined(__APPLE__)
// Defined in GlfwCocoaView.mm — returns the window's layer-backed CALayer,
// which is what ANGLE/Metal accepts as a native window.
void* GlfwCocoaLayer(GLFWwindow* window);
// Defined in GlfwCocoaView.mm — sets the CALayer contentsScale to the window's
// backingScaleFactor so the drawable matches the physical framebuffer.
void GlfwCocoaSetLayerScale(GLFWwindow* window);
// Defined in GlfwCocoaView.mm — reads back the layer's actual contentsScale and
// the window's backingScaleFactor; the ENG-08 gate asserts they are equal.
double GlfwCocoaLayerContentsScale(GLFWwindow* window);
double GlfwCocoaBackingScale(GLFWwindow* window);
// Defined in GlfwCocoaView.mm — sets the app cursor to NSCursor open/closed
// hand (GLFW 3.4 has no grab shape). grabbing=false is the open hand (kind 3),
// grabbing=true the closed hand (kind 4).
void GlfwCocoaSetGrabCursor(GLFWwindow* window, bool grabbing);
#endif

namespace {
#if defined(__APPLE__)
// ⛔ eglGetProcAddress, NOT glfwGetProcAddress, ON DARWIN.
// GLFW created the window with GLFW_NO_API here, so it owns no GL context and
// its loader resolves nothing. Impeller would get a table of null pointers and
// fail somewhere far away from the cause.
void* ProcAddr(const char* name, void*) { return (void*)eglGetProcAddress(name); }
#else
void* ProcAddr(const char* name, void*) { return (void*)glfwGetProcAddress(name); }
#endif

void GlfwErrorCallback(int error, const char* description) {
  fprintf(stderr, "rn-impeller: GLFW error (%d): %s\n", error, description);
  fflush(stderr);
}

// desktop-input-gap P0 item 1. GLFW_KEY_* -> W3C `key`/`code` translation.
//
// ⛔ WHY TWO STRINGS, TWO DIFFERENT SOURCES.
// `code` names the PHYSICAL key position and is layout-INDEPENDENT (the key
// two right of Tab is always "KeyA" on a US keyboard's physical layout, even
// when a French AZERTY layout makes it type 'q') -- it comes straight out of
// the GLFW_KEY_* token, which IS physical. `key` names what the key actually
// PRODUCES and must honour the layout, which for the printable range only
// glfwGetKeyName can answer; for control keys (arrows, Tab, Escape, ...) the
// two happen to read the same because there is no alternate layout mapping
// for "the Escape key".
//
// Returns false only for GLFW_KEY_UNKNOWN (scancode not recognised by GLFW
// at all) -- every recognised key gets SOME mapping, falling back to the
// bare code name for anything this table does not name individually (rare
// OEM/world keys) rather than silently producing an empty string.
bool TranslateGlfwKey(int glfwKey, int scancode, std::string* outKey,
                      std::string* outCode) {
  switch (glfwKey) {
    case GLFW_KEY_UNKNOWN:
      return false;
    // Navigation / editing.
    case GLFW_KEY_LEFT:      *outKey = *outCode = "ArrowLeft"; return true;
    case GLFW_KEY_RIGHT:     *outKey = *outCode = "ArrowRight"; return true;
    case GLFW_KEY_UP:        *outKey = *outCode = "ArrowUp"; return true;
    case GLFW_KEY_DOWN:      *outKey = *outCode = "ArrowDown"; return true;
    case GLFW_KEY_HOME:      *outKey = *outCode = "Home"; return true;
    case GLFW_KEY_END:       *outKey = *outCode = "End"; return true;
    case GLFW_KEY_PAGE_UP:   *outKey = *outCode = "PageUp"; return true;
    case GLFW_KEY_PAGE_DOWN: *outKey = *outCode = "PageDown"; return true;
    case GLFW_KEY_DELETE:    *outKey = *outCode = "Delete"; return true;
    case GLFW_KEY_BACKSPACE: *outKey = *outCode = "Backspace"; return true;
    case GLFW_KEY_ENTER:     *outKey = *outCode = "Enter"; return true;
    case GLFW_KEY_TAB:       *outKey = *outCode = "Tab"; return true;
    case GLFW_KEY_ESCAPE:    *outKey = *outCode = "Escape"; return true;
    case GLFW_KEY_INSERT:    *outKey = *outCode = "Insert"; return true;
    case GLFW_KEY_MENU:      *outKey = "ContextMenu"; *outCode = "ContextMenu"; return true;
    case GLFW_KEY_PRINT_SCREEN: *outKey = *outCode = "PrintScreen"; return true;
    case GLFW_KEY_PAUSE:     *outKey = *outCode = "Pause"; return true;
    case GLFW_KEY_SCROLL_LOCK: *outKey = *outCode = "ScrollLock"; return true;
    // Locks and modifiers -- `key` is the neutral W3C name; `code` carries
    // the physical left/right distinction the DOM also exposes.
    case GLFW_KEY_CAPS_LOCK:    *outKey = *outCode = "CapsLock"; return true;
    case GLFW_KEY_NUM_LOCK:     *outKey = *outCode = "NumLock"; return true;
    case GLFW_KEY_LEFT_SHIFT:   *outKey = "Shift"; *outCode = "ShiftLeft"; return true;
    case GLFW_KEY_RIGHT_SHIFT:  *outKey = "Shift"; *outCode = "ShiftRight"; return true;
    case GLFW_KEY_LEFT_CONTROL: *outKey = "Control"; *outCode = "ControlLeft"; return true;
    case GLFW_KEY_RIGHT_CONTROL:*outKey = "Control"; *outCode = "ControlRight"; return true;
    case GLFW_KEY_LEFT_ALT:     *outKey = "Alt"; *outCode = "AltLeft"; return true;
    case GLFW_KEY_RIGHT_ALT:    *outKey = "Alt"; *outCode = "AltRight"; return true;
    // GLFW_MOD_SUPER / W3C "Meta" -- Cmd on macOS, Super/Win elsewhere.
    case GLFW_KEY_LEFT_SUPER:   *outKey = "Meta"; *outCode = "MetaLeft"; return true;
    case GLFW_KEY_RIGHT_SUPER:  *outKey = "Meta"; *outCode = "MetaRight"; return true;
    // Numpad. GLFW_KEY_KP_0..KP_EQUAL are in GLFW's own "printable" set
    // (glfwGetKeyName answers them), but KP_ENTER is not -- it has a fixed
    // "Enter"/"NumpadEnter" identity like the control keys above.
    case GLFW_KEY_KP_ENTER: *outKey = "Enter"; *outCode = "NumpadEnter"; return true;
    case GLFW_KEY_KP_0: case GLFW_KEY_KP_1: case GLFW_KEY_KP_2:
    case GLFW_KEY_KP_3: case GLFW_KEY_KP_4: case GLFW_KEY_KP_5:
    case GLFW_KEY_KP_6: case GLFW_KEY_KP_7: case GLFW_KEY_KP_8:
    case GLFW_KEY_KP_9: {
      *outCode = "Numpad" + std::to_string(glfwKey - GLFW_KEY_KP_0);
      const char* name = glfwGetKeyName(glfwKey, scancode);
      *outKey = name ? name : outCode->substr(6);
      return true;
    }
    case GLFW_KEY_KP_DECIMAL:  *outCode = "NumpadDecimal"; goto numpad_name;
    case GLFW_KEY_KP_DIVIDE:   *outCode = "NumpadDivide"; goto numpad_name;
    case GLFW_KEY_KP_MULTIPLY: *outCode = "NumpadMultiply"; goto numpad_name;
    case GLFW_KEY_KP_SUBTRACT: *outCode = "NumpadSubtract"; goto numpad_name;
    case GLFW_KEY_KP_ADD:      *outCode = "NumpadAdd"; goto numpad_name;
    case GLFW_KEY_KP_EQUAL:    *outCode = "NumpadEqual"; goto numpad_name;
    numpad_name: {
      const char* name = glfwGetKeyName(glfwKey, scancode);
      *outKey = name ? name : *outCode;
      return true;
    }
    default:
      break;
  }
  // Function keys: F1..F25, code == key.
  if (glfwKey >= GLFW_KEY_F1 && glfwKey <= GLFW_KEY_F25) {
    *outKey = *outCode = "F" + std::to_string(glfwKey - GLFW_KEY_F1 + 1);
    return true;
  }
  // Letters: A..Z. `code` is the PHYSICAL position (always "KeyA" for the
  // key GLFW calls GLFW_KEY_A, regardless of what it types under a non-US
  // layout); `key` is what it actually produces -- glfwGetKeyName, which IS
  // layout-correct, falling back to the US letter if the platform cannot
  // name it (a is GLFW's baseline; shift-casing is applied by the caller
  // reading the `shift` modifier, matching every other browser's `key`
  // which reports the unshifted letter -- 'a', not 'A' -- for a plain press
  // and leaves case-folding to the consumer, exactly as `onKeyPress`'s text
  // callback already does via the separate, layout-aware char callback).
  if (glfwKey >= GLFW_KEY_A && glfwKey <= GLFW_KEY_Z) {
    *outCode = std::string("Key") + char('A' + (glfwKey - GLFW_KEY_A));
    const char* name = glfwGetKeyName(glfwKey, scancode);
    *outKey = name ? name : std::string(1, char('a' + (glfwKey - GLFW_KEY_A)));
    return true;
  }
  // Digits: 0..9.
  if (glfwKey >= GLFW_KEY_0 && glfwKey <= GLFW_KEY_9) {
    *outCode = "Digit" + std::to_string(glfwKey - GLFW_KEY_0);
    const char* name = glfwGetKeyName(glfwKey, scancode);
    *outKey = name ? name : std::to_string(glfwKey - GLFW_KEY_0);
    return true;
  }
  // Remaining printable punctuation: GLFW names them layout-correctly for
  // `key`; `code` gets the W3C UI Events physical name for the US position.
  struct PunctCode { int glfwKey; const char* code; };
  static const PunctCode kPunct[] = {
      {GLFW_KEY_SPACE, "Space"},          {GLFW_KEY_APOSTROPHE, "Quote"},
      {GLFW_KEY_COMMA, "Comma"},          {GLFW_KEY_MINUS, "Minus"},
      {GLFW_KEY_PERIOD, "Period"},        {GLFW_KEY_SLASH, "Slash"},
      {GLFW_KEY_SEMICOLON, "Semicolon"},  {GLFW_KEY_EQUAL, "Equal"},
      {GLFW_KEY_LEFT_BRACKET, "BracketLeft"},
      {GLFW_KEY_BACKSLASH, "Backslash"},
      {GLFW_KEY_RIGHT_BRACKET, "BracketRight"},
      {GLFW_KEY_GRAVE_ACCENT, "Backquote"},
  };
  for (const auto& p : kPunct) {
    if (p.glfwKey == glfwKey) {
      *outCode = p.code;
      const char* name = glfwGetKeyName(glfwKey, scancode);
      *outKey = name ? name : p.code;
      return true;
    }
  }
  // GLFW_KEY_WORLD_1/2 and anything else recognised but unnamed here: report
  // the GLFW-given printable name if there is one, else "Unidentified" -- a
  // real key that this table has no individual entry for, not a dropped one.
  const char* name = glfwGetKeyName(glfwKey, scancode);
  *outKey = name ? name : "Unidentified";
  *outCode = "Unidentified";
  return true;
}

// Reverse of TranslateGlfwKey, for synthesiseKey(): W3C `key` name -> the
// GLFW_KEY_* token that produces it. Only needs to cover the names the gate
// fixture and the mutation suite actually send; unknown names return false
// rather than guessing, so a typo in a gate fails loudly instead of silently
// synthesising nothing.
bool GlfwKeyFromName(const std::string& name, int* outKey) {
  static const std::unordered_map<std::string, int> kByName = {
      {"ArrowLeft", GLFW_KEY_LEFT},       {"ArrowRight", GLFW_KEY_RIGHT},
      {"ArrowUp", GLFW_KEY_UP},           {"ArrowDown", GLFW_KEY_DOWN},
      {"Home", GLFW_KEY_HOME},            {"End", GLFW_KEY_END},
      {"PageUp", GLFW_KEY_PAGE_UP},       {"PageDown", GLFW_KEY_PAGE_DOWN},
      {"Delete", GLFW_KEY_DELETE},        {"Backspace", GLFW_KEY_BACKSPACE},
      {"Enter", GLFW_KEY_ENTER},          {"Tab", GLFW_KEY_TAB},
      {"Escape", GLFW_KEY_ESCAPE},        {"Insert", GLFW_KEY_INSERT},
      {"ContextMenu", GLFW_KEY_MENU},     {"CapsLock", GLFW_KEY_CAPS_LOCK},
      {"Shift", GLFW_KEY_LEFT_SHIFT},     {"Control", GLFW_KEY_LEFT_CONTROL},
      {"Alt", GLFW_KEY_LEFT_ALT},         {"Meta", GLFW_KEY_LEFT_SUPER},
      {"Space", GLFW_KEY_SPACE},
  };
  auto it = kByName.find(name);
  if (it != kByName.end()) {
    *outKey = it->second;
    return true;
  }
  if (name.size() == 1) {
    const char c = name[0];
    if (c >= 'a' && c <= 'z') { *outKey = GLFW_KEY_A + (c - 'a'); return true; }
    if (c >= 'A' && c <= 'Z') { *outKey = GLFW_KEY_A + (c - 'A'); return true; }
    if (c >= '0' && c <= '9') { *outKey = GLFW_KEY_0 + (c - '0'); return true; }
  }
  if (name.size() == 2 && name[0] == 'F') {
    const int n = name[1] - '0';
    if (n >= 1 && n <= 9) { *outKey = GLFW_KEY_F1 + (n - 1); return true; }
  }
  return false;
}
}  // namespace

GlfwSurface::~GlfwSurface() {
  if (typography_) ImpellerTypographyContextRelease(typography_);
  if (surface_) ImpellerSurfaceRelease(surface_);
  if (context_) ImpellerContextRelease(context_);
  // ENG-09 hover/cursor. Destroy the standard cursors before glfwTerminate,
  // which would otherwise leak them (GLFW frees its own on terminate, but
  // being explicit keeps the ownership obvious and survives a future move to
  // not calling glfwTerminate here).
  if (arrowCursor_) glfwDestroyCursor(arrowCursor_);
  if (handCursor_) glfwDestroyCursor(handCursor_);
  if (ibeamCursor_) glfwDestroyCursor(ibeamCursor_);
  for (GLFWcursor* c : shapeCursors_) {
    if (c) glfwDestroyCursor(c);
  }
#if defined(__APPLE__)
  if (display_ != EGL_NO_DISPLAY) {
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (eglSurface_ != EGL_NO_SURFACE) eglDestroySurface(display_, eglSurface_);
    if (eglContext_ != EGL_NO_CONTEXT) eglDestroyContext(display_, eglContext_);
    eglTerminate(display_);
  }
  if (window_) glfwDestroyWindow(window_);
#else
  if (window_) {
    glfwMakeContextCurrent(nullptr);
    glfwDestroyWindow(window_);
  }
#endif
  glfwTerminate();
}

#if defined(__APPLE__)
bool GlfwSurface::initAngleForWindow(std::string* error) {
  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };

  auto getPlatformDisplay =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
  if (!getPlatformDisplay) return fail("eglGetPlatformDisplayEXT unavailable");

  // Identical acquisition to HeadlessSurface::init — including PRINTING the
  // backend that actually took, never inferring it. A silent fallback from
  // METAL to DEFAULT renders correctly and identically, which is exactly how a
  // platform gets declared working on a path it never took.
  //
  // The cast: eglplatform.h makes EGLNativeDisplayType a plain `int` on Apple,
  // so reinterpret_cast is the one spelling valid for both integer and pointer
  // sources. See the long note in HeadlessSurface.cpp.
  struct Attempt { const char* name; EGLint type; };
  const Attempt attempts[] = {
      {"METAL", EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE},
      {"DEFAULT", EGL_PLATFORM_ANGLE_TYPE_DEFAULT_ANGLE},
  };
  for (const auto& a : attempts) {
    const EGLint dpyAttrs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, a.type, EGL_NONE};
    EGLDisplay d = getPlatformDisplay(
        EGL_PLATFORM_ANGLE_ANGLE,
        reinterpret_cast<void*>(EGL_DEFAULT_DISPLAY), dpyAttrs);
    if (d == EGL_NO_DISPLAY) continue;
    EGLint maj = 0, min = 0;
    if (!eglInitialize(d, &maj, &min)) continue;
    display_ = d;
    fprintf(stderr, "rn-impeller: ANGLE backend=%s (windowed)\n", a.name);
    break;
  }
  if (display_ == EGL_NO_DISPLAY) return fail("no ANGLE display could be initialised");

  // ⛔ EGL_WINDOW_BIT, NOT EGL_PBUFFER_BIT. This is the only substantive
  // difference from the headless config: a pbuffer config will be returned
  // happily by eglChooseConfig and then rejected by eglCreateWindowSurface.
  //
  // ⛔ AND EGL_STENCIL_SIZE 8 IS NOT OPTIONAL. Unlike HeadlessSurface, which
  // owns its FBO and can attach a renderbuffer, this path draws into the
  // window's DEFAULT framebuffer (fbo 0) — so its stencil comes from the
  // EGLConfig and from nowhere else. Impeller fills non-convex paths with
  // stencil-then-cover; with no stencil bits the accumulate pass is a no-op and
  // the unmasked cover geometry paints the path's BOUNDING BOX. Convex fills
  // and all strokes stay pixel-exact, so this presents as "concave SVG paths
  // paint as slabs" with a clean log and no GL error. Measured 2026-09-11 on
  // the headless twin of this bug: an L, an arrowhead and a notched diamond
  // each painted 6400 (their 80x80 box) instead of 4800/4800/3000.
  const EGLint cfgAttrs[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                             EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                             EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                             EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
                             EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8, EGL_NONE};
  EGLConfig cfg;
  EGLint n = 0;
  if (!eglChooseConfig(display_, cfgAttrs, &cfg, 1, &n) || n != 1) {
    return fail("eglChooseConfig (window) failed");
  }
  if (!eglBindAPI(EGL_OPENGL_ES_API)) return fail("eglBindAPI failed");

  void* layer = GlfwCocoaLayer(window_);
  if (!layer) return fail("glfwGetCocoaWindow/contentView layer was null");

  // FRAME-ONE SCALE. HostApp.app opens on 1x and may never resize, so the resize
  // callback that drives consumeDirty() can never fire. Set contentsScale here,
  // before the first present, or frame one paints a quarter window on hi-dpi.
  GlfwCocoaSetLayerScale(window_);
  // ENG-08 OBSERVABLE. Print the layer's ACTUAL contentsScale (read back, not
  // the value we intended) beside the window's backingScaleFactor, ONCE, before
  // the first present. The gate asserts these are equal; reading real state is
  // what makes it go red if GlfwCocoaSetLayerScale is ever dropped.
  fprintf(stderr,
          "rn-impeller: layer contents_scale=%.2f backing_scale=%.2f\n",
          GlfwCocoaLayerContentsScale(window_), GlfwCocoaBackingScale(window_));

  eglSurface_ = eglCreateWindowSurface(display_, cfg,
                                       (EGLNativeWindowType)layer, nullptr);
  if (eglSurface_ == EGL_NO_SURFACE) {
    // PRINT THE EGL ERROR CODE. Without it this line says only "failed" and
    // gives no way to tell a bad native window (0x300B, the wrong pointer
    // type) from a bad config match (0x3005) — which cost a full build+gate
    // round trip to distinguish once already.
    fprintf(stderr, "rn-impeller: eglCreateWindowSurface eglGetError=0x%04x\n",
            eglGetError());
    return fail("eglCreateWindowSurface failed");
  }

  // FP-05: a debug context so Mesa/ANGLE report API errors through KHR_debug.
  const EGLint dbg = rni::glvalidation::Enabled() ? 1 : 0;
  const EGLint ctxAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, 0x31B0 /*EGL_CONTEXT_OPENGL_DEBUG*/, dbg,
                             EGL_NONE};
  eglContext_ = eglCreateContext(display_, cfg, EGL_NO_CONTEXT, ctxAttrs);
  if (eglContext_ == EGL_NO_CONTEXT) return fail("eglCreateContext failed");
  if (!eglMakeCurrent(display_, eglSurface_, eglSurface_, eglContext_)) {
    return fail("eglMakeCurrent (window) failed");
  }
  return true;
}
#endif

bool GlfwSurface::init(int width, int height, std::string* error) {
  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };

  glfwSetErrorCallback(GlfwErrorCallback);
#if defined(_WIN32)
  // ANGLE's D3D11 backend, the same one WinGLSurface picks for headless.
  glfwInitHint(GLFW_ANGLE_PLATFORM_TYPE, GLFW_ANGLE_PLATFORM_TYPE_D3D11);
#endif
  if (!glfwInit()) return fail("glfwInit failed");

#if defined(__APPLE__)
  // ⛔ GLFW MUST NOT TRY TO MAKE A CONTEXT ON DARWIN.
  // The Linux hint below (GLFW_EGL_CONTEXT_API) asks GLFW for a SYSTEM EGL.
  // macOS has none, so GLFW refuses the window outright with
  // "EGL: Failed to find support for OpenGL" and glfwCreateWindow returns null
  // — before any of our code runs, which makes it read like an ANGLE problem
  // when ANGLE has not been consulted yet.
  //
  // GLFW_NO_API means GLFW owns the window and its event loop ONLY; we build
  // the ANGLE display/context ourselves and attach it to the view's CALayer,
  // exactly as HeadlessSurface builds its offscreen one.
  glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
#else
  // EGL context creation API, exactly as tools/window-spike.sh's
  // example_gl.c does — GLFW defaults to its native (GLX) API, and Impeller's
  // ProcAddressCallback here is glfwGetProcAddress, which only resolves GLES
  // symbols correctly when the context was created through EGL.
  glfwWindowHint(GLFW_CONTEXT_CREATION_API, GLFW_EGL_CONTEXT_API);
#if defined(_WIN32)
  // GLFW's EGL path loads libEGL.dll/libGLESv2.dll (ANGLE, shipped beside
  // the exe). ANGLE implements GLES only, so the client API must be ES 3.0;
  // GLFW's desktop-GL default makes glfwCreateWindow fail.
  glfwWindowHint(GLFW_CLIENT_API, GLFW_OPENGL_ES_API);
  glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
  if (rni::glvalidation::Enabled()) glfwWindowHint(GLFW_OPENGL_DEBUG_CONTEXT, GLFW_TRUE);  // FP-05
  glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 0);
#endif
#endif

  // ⛔ ENG-05b: THE GLFW_SAMPLES EXPERIMENT, BEHIND A FLAG, AND EXPECTED TO DO
  // NOTHING. Set RNI_GLFW_SAMPLES=N to request an N-sample default framebuffer.
  //
  // The macOS peer proposed this as the remaining ENG-05b lead: GlfwSurface
  // draws into fbo 0, whose sample count comes from the window's framebuffer
  // config, and nothing here ever asked for multisampling. That reasoning is
  // sound and the request is now real -- but the spike already answered the
  // question it is asking, and the answer was no.
  //
  // engine/spike/aa_sample_count.cpp arm B hands Impeller a 4x MSAA
  // renderbuffer through ImpellerSurfaceCreateWrappedFBONew -- the SAME call
  // this file makes for fbo 0 -- and the readback is BYTE-IDENTICAL to the
  // single-sample arm A (FILL 3.2% partial / 50 distinct, STROKE 26.7% / 82,
  // both arms). Impeller resolves its own AA internally into an offscreen MSAA
  // texture and the sample count of the target we hand it is not consulted.
  // Re-measured on this binary 2026-09-11, unchanged.
  //
  // So this hint is kept OFF by default and exists to be FALSIFIED on hardware:
  // it costs one env var to re-run the matched pair on a real GPU, where
  // GL_EXT_multisampled_render_to_texture exists and llvmpipe's behaviour may
  // not hold. Turning it on by default would be shipping a config change with
  // no measured effect, which is how a placebo ends up load-bearing.
  if (const char* samples = std::getenv("RNI_GLFW_SAMPLES")) {
    const int n = std::atoi(samples);
    if (n > 0) {
      glfwWindowHint(GLFW_SAMPLES, n);
      // Printed, not silent: an unhonoured hint is indistinguishable from an
      // ignored one, and the whole point of the flag is knowing which.
      std::printf("rn-impeller: glfw_samples_requested=%d\n", n);
      std::fflush(stdout);
    }
  }

  // ⛔ ITEM 3: A ZERO WIDTH/HEIGHT MEANS "SIZE TO THE DISPLAY", NOT A ZERO
  // WINDOW. The host passes 0 for either axis when the user gave no --width/
  // --height (see main.cpp's widthGiven/heightGiven). glfwCreateWindow(0,0)
  // would fail or open a degenerate window, so resolve the auto axes here,
  // AFTER glfwInit (glfwGetPrimaryMonitor needs it) and BEFORE the window is
  // created. The default is ~70% of the monitor's WORK AREA -- not the full
  // monitor size, which would sit under the menu bar / taskbar -- centred in
  // that work area, with a floor near 1024x700 so a tiny or unreported monitor
  // still yields a usable window. --width/--height override per-axis: a given
  // axis arrives non-zero and is used verbatim, so `--width 800` with no
  // --height gets an 800-wide window at the derived height.
  bool autoSized = false;
  if (width <= 0 || height <= 0) {
    // Work area excludes OS chrome (macOS menu bar, Linux/Win taskbar); the
    // monitor's full mode would put our title bar off-screen on some WMs.
    int waX = 0, waY = 0, waW = 0, waH = 0;
    if (GLFWmonitor* mon = glfwGetPrimaryMonitor()) {
      glfwGetMonitorWorkarea(mon, &waX, &waY, &waW, &waH);
    }
    // A monitor that reports nothing (headless X, some VMs) must not collapse
    // the window to 0; fall back to the floor so the app still opens.
    const int kFloorW = 1024, kFloorH = 700;
    auto derive = [&](int given, int workExtent, int floor) -> int {
      if (given > 0) return given;                 // explicit axis wins
      int seventy = workExtent > 0 ? (workExtent * 7) / 10 : 0;
      return seventy > floor ? seventy : floor;    // ~70%, never below floor
    };
    width = derive(width, waW, kFloorW);
    height = derive(height, waH, kFloorH);
    autoSized = true;
    std::printf("rn-impeller: window_default size=%dx%d workarea=%dx%d\n",
                width, height, waW, waH);
    std::fflush(stdout);
  }

  window_ = glfwCreateWindow(width, height, title_.c_str(), nullptr, nullptr);
  if (!window_) return fail("glfwCreateWindow failed");

  // ⛔ CENTRE IN THE MONITOR WORK AREA WHEN WE CHOSE THE SIZE OURSELVES.
  // GLFW places a new window wherever the WM decides (often 0,0 -> under the
  // menu bar). When the size came from the display we also own the position:
  // centre the window in the work area so it opens where a real app would,
  // not jammed into a corner. Skipped when both axes were explicit -- a caller
  // that asked for an exact size is not asking us to move it.
  if (autoSized) {
    if (GLFWmonitor* mon = glfwGetPrimaryMonitor()) {
      int waX = 0, waY = 0, waW = 0, waH = 0;
      glfwGetMonitorWorkarea(mon, &waX, &waY, &waW, &waH);
      if (waW > 0 && waH > 0) {
        int winW = 0, winH = 0;
        glfwGetWindowSize(window_, &winW, &winH);
        glfwSetWindowPos(window_, waX + (waW - winW) / 2,
                         waY + (waH - winH) / 2);
      }
    }
  }

  int fbWidth = 0, fbHeight = 0;
  glfwGetFramebufferSize(window_, &fbWidth, &fbHeight);
  width_ = fbWidth;
  height_ = fbHeight;

  // ⛔ RECORD THE POINT SIZE TOO — THE WINDOW MAY NOT BE THE SIZE WE ASKED FOR.
  // glfwCreateWindow's arguments are a REQUEST in screen coordinates; a window
  // manager, a fullscreen constraint or a DPI policy can hand back something
  // else. Reading it back rather than reusing `width`/`height` means the
  // pixels:points ratio the host derives is a property of the window that
  // actually exists, not of the numbers we hoped for.
  int winWidth = 0, winHeight = 0;
  glfwGetWindowSize(window_, &winWidth, &winHeight);
  pointWidth_ = winWidth;
  pointHeight_ = winHeight;

  // ⛔ OBSERVE THE WINDOW, DO NOT JUST MEASURE IT ONCE.
  // Everything above runs exactly once. Without this callback the backing
  // scale and the surface size are frozen at whatever the window was when it
  // opened, so a resize paints the old geometry into a new framebuffer and a
  // drag to a 1x monitor keeps rasterising at 2x. GLFW fires this for BOTH,
  // because a scale change on the same logical window size still changes the
  // framebuffer size in pixels -- which is exactly why the framebuffer
  // callback is the right one to listen on and the window-size callback is
  // not.
  //
  // `this` reaches the callback through the window's user pointer; GLFW's C
  // API has no other channel. Only the flag is set here: see GlfwSurface.h on
  // why the GL work belongs to the frame loop.
  glfwSetWindowUserPointer(window_, this);
  // desktop-input-gap P0 item 1. Ask X11/Win32 to fold Caps/Num Lock into the
  // mods bitmask every key event carries (GLFW_MOD_CAPS_LOCK/NUM_LOCK),
  // rather than the default of reporting only transient modifiers. Without
  // this a real Caps Lock key produces a key event with capsLock=false no
  // matter how the lock state sits, because GLFW_LOCK_KEY_MODS defaults OFF.
  glfwSetInputMode(window_, GLFW_LOCK_KEY_MODS, GLFW_TRUE);
  glfwSetFramebufferSizeCallback(
      window_, [](GLFWwindow* w, int, int) {
        auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
        if (self) self->dirty_.store(true, std::memory_order_release);
      });

  // ⛔ MARKING DIRTY IS NOT ENOUGH DURING A LIVE DRAG — SEE GlfwSurface.h.
  // The callback above raises a flag whose ONLY consumer is the frame loop,
  // and on macOS that loop is blocked inside glfwPollEvents for the entire
  // duration of a window-edge drag (AppKit's modal resize loop runs inside
  // -[NSWindow sendEvent:]). GLFW invokes the REFRESH callback from inside
  // that same modal loop, so this is the one place a frame can be produced
  // while the drag is still in progress.
  //
  // Registered unconditionally, not under #if defined(__APPLE__): X11 raises
  // it on Expose and Win32 on WM_PAINT, where repainting on damage is
  // correct-by-definition rather than a workaround. The handler is
  // no-op-cheap when the geometry has not changed (consumeDirty() returns
  // false), so the non-darwin cost is one extra paint per exposure event, not
  // a double-paint per frame: the steady-state frame loop is untouched.
  glfwSetWindowRefreshCallback(window_, [](GLFWwindow* w) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self || !self->refreshHandler_) return;
    // Drops the callback when ANY paint is on the stack, including one the
    // frame loop started -- see PaintScope in GlfwSurface.h. The handler
    // itself raises this flag via its own PaintScope, so this still covers
    // refresh-re-entering-refresh; it just no longer covers ONLY that.
    if (self->paintInFlight_) return;
    self->refreshHandler_();
  });

  // ⛔ THE REGISTRATION THAT WAS ABSENT. Without this line the windowed app
  // mounts, lays out, paints, hit-tests correctly if asked — and no click ever
  // asks. glfwSetMouseButtonCallback was measured at ZERO occurrences in this
  // tree on 2026-09-09, which is why 13 wired onPress handlers in hostapp v5 were
  // inert while tools/ci-input.sh (headless `--tap`) stayed green.
  //
  // ⛔ THE POSITION IS READ HERE, NOT TRACKED FROM A CURSOR-MOVE CALLBACK.
  // GLFW guarantees glfwGetCursorPos is current inside the button callback,
  // and reading it at the press is strictly more correct than replaying the
  // last cursor-position event: a click delivered without an intervening move
  // (window focus click, a synthetic XTest click that warps then clicks, a
  // tap on a trackpad) has no prior move to have recorded. A cursor-position
  // callback would additionally fire hundreds of times per second to maintain
  // state nothing reads between presses.
  glfwSetMouseButtonCallback(window_, [](GLFWwindow* w, int button, int action,
                                         int mods) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self) return;
    if (action != GLFW_PRESS && action != GLFW_RELEASE) return;
    double cx = 0.0, cy = 0.0;
    glfwGetCursorPos(w, &cx, &cy);
    const bool down = action == GLFW_PRESS;
    // item 6: only LEFT is an RN touch (onPress, focus, caret, selection).
    // Right/middle/back/forward go to the extra-button path: W3C pointer
    // events only. GLFW maps X11 buttons 8/9 and Win32 XBUTTON1/2 to
    // BUTTON_4/BUTTON_5 (back/forward).
    int w3c = -1;
    switch (button) {
      case GLFW_MOUSE_BUTTON_LEFT: w3c = 0; break;
      case GLFW_MOUSE_BUTTON_MIDDLE: w3c = 1; break;
      case GLFW_MOUSE_BUTTON_RIGHT: w3c = 2; break;
      case GLFW_MOUSE_BUTTON_4: w3c = 3; break;
      case GLFW_MOUSE_BUTTON_5: w3c = 4; break;
      default: return;
    }
    self->routeButton(cx, cy, down, w3c, mods);
  });

  // <ScrollView>. ENG-02. THE SECOND REGISTRATION THAT WAS ABSENT.
  // glfwSetScrollCallback was measured at ZERO occurrences in this tree before
  // this line, exactly as glfwSetMouseButtonCallback was before the block
  // above. Same failure shape: a <ScrollView> mounts, lays out, paints its
  // first screenful and never moves, and nothing logs.
  //
  // ⛔ THE POSITION IS READ AT THE EVENT, NOT TRACKED. Same argument as the
  // button callback: GLFW guarantees glfwGetCursorPos is current here, and a
  // wheel event can arrive with no preceding cursor-move to have recorded
  // (wheel over a window that just gained focus).
  glfwSetScrollCallback(window_, [](GLFWwindow* w, double xoffset,
                                    double yoffset) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self || !self->scrollHandler_) return;
    double cx = 0.0, cy = 0.0;
    glfwGetCursorPos(w, &cx, &cy);
    self->dispatchScrollPoint(cx, cy, xoffset, yoffset);
  });

  // ENG-09 hover/cursor. THE THIRD REGISTRATION THAT WAS ABSENT.
  // glfwSetCursorPosCallback was measured at ZERO occurrences in this tree
  // before this line (see the header's P9 note, which recorded it absent
  // alongside the mouse-button one). Same failure shape as clicks and scroll:
  // pointerenter/leave and the cursor shape have been implementable in
  // FabricHost and paintable all along, and nothing moved the mouse. A view
  // with an onPointerEnter hover style would mount, paint its resting state
  // and never light up, and no line would log.
  //
  // ⛔ UNLIKE THE BUTTON CALLBACK, THE POSITION IS THE CALLBACK'S ARGUMENT.
  // glfwSetCursorPosCallback delivers x/y directly, so there is no
  // glfwGetCursorPos here -- the argument IS the current position, by
  // definition. dispatchHoverPoint does the one-place screen->points
  // conversion, exactly as the click and scroll paths do.
  glfwSetCursorPosCallback(window_, [](GLFWwindow* w, double x, double y) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self || !self->hoverHandler_) return;
    self->dispatchHoverPoint(x, y);
  });

  // ENG-09 hover/cursor. THE OTHER HALF: clear the hovered control when the
  // cursor LEAVES the window. Without this a control the mouse was over when
  // it exited the window stays visually hovered forever -- glfwSetCursorPos
  // stops firing at the edge, so the last hovered tag never gets its
  // pointerleave. GLFW_TRUE on enter, GLFW_FALSE on leave; only the leave is
  // acted on (an enter's first move fires the position callback anyway).
  glfwSetCursorEnterCallback(window_, [](GLFWwindow* w, int entered) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self) return;
    if (entered == GLFW_FALSE && self->cursorLeaveHandler_) {
      self->cursorLeaveHandler_();
      // Reset to arrow: the next window the cursor is over owns its own shape.
      self->applyCursorKind(0);
    }
  });

  // <TextInput>. ENG-01b. THE KEYBOARD REGISTRATIONS THAT WERE ABSENT.
  // glfwSetCharCallback and glfwSetKeyCallback were measured at ZERO occurrences
  // in this tree before this, exactly as the mouse/scroll/cursor callbacks each
  // were in turn. Same failure shape: a focused field paints its caret, the JS
  // has onChangeText wired, and not one keystroke ever arrives.
  //
  // The CHAR callback carries a DECODED codepoint (layout- and dead-key-aware);
  // it is the only correct source of a typed character. Control keys never reach
  // it, which is why they go through the KEY callback below.
  glfwSetCharCallback(window_, [](GLFWwindow* w, unsigned int codepoint) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self || !self->charHandler_) return;
    self->charHandler_(codepoint);
  });
  // desktop-input-gap P0 item 1. THE KEY CALLBACK NOW FORWARDS EVERY KEY.
  //
  // ⛔ WHAT THIS REPLACES. Until now this callback dropped GLFW_RELEASE
  // outright, recognised only GLFW_KEY_BACKSPACE/ENTER/KP_ENTER, ignored
  // every other key entirely, and read mods for Shift only. An
  // ArrowLeft/Tab/Escape/Ctrl+A/etc. keypress produced NOTHING: no callback
  // ran, no line printed, no event reached JS. That is invisible to
  // ci-textedit.sh (which only ever sends Backspace/Enter/characters) and to
  // every mouse/scroll/hover gate, so it shipped unnoticed the same way the
  // absent mouse-button registration once did (see the P9 note on
  // setMouseButtonHandler above).
  //
  // The full translation lives in dispatchKeyEvent (below), shared with
  // synthesiseKey() so a synthetic gate exercises the identical table a real
  // keypress does. This callback's only job is handing GLFW's raw ints to it.
  glfwSetKeyCallback(window_, [](GLFWwindow* w, int key, int scancode,
                                 int action, int mods) {
    auto* self = static_cast<GlfwSurface*>(glfwGetWindowUserPointer(w));
    if (!self) return;
    self->dispatchKeyEvent(key, scancode, action, mods);
  });

  // ENG-09 hover/cursor. The three standard cursors, created ONCE (not per
  // move). glfwCreateStandardCursor returns null if the platform lacks the
  // shape; applyCursorKind tolerates a null by leaving the cursor unchanged,
  // so a missing hand cursor degrades to "no shape change", never a crash.
  arrowCursor_ = glfwCreateStandardCursor(GLFW_ARROW_CURSOR);
  handCursor_ = glfwCreateStandardCursor(GLFW_HAND_CURSOR);
  ibeamCursor_ = glfwCreateStandardCursor(GLFW_IBEAM_CURSOR);
  shapeCursors_[rni::kCursorCrosshair] = glfwCreateStandardCursor(GLFW_CROSSHAIR_CURSOR);
  shapeCursors_[rni::kCursorResizeEW] = glfwCreateStandardCursor(GLFW_RESIZE_EW_CURSOR);
  shapeCursors_[rni::kCursorResizeNS] = glfwCreateStandardCursor(GLFW_RESIZE_NS_CURSOR);
  shapeCursors_[rni::kCursorResizeNWSE] = glfwCreateStandardCursor(GLFW_RESIZE_NWSE_CURSOR);
  shapeCursors_[rni::kCursorResizeNESW] = glfwCreateStandardCursor(GLFW_RESIZE_NESW_CURSOR);
  shapeCursors_[rni::kCursorResizeAll] = glfwCreateStandardCursor(GLFW_RESIZE_ALL_CURSOR);
  shapeCursors_[rni::kCursorNotAllowed] = glfwCreateStandardCursor(GLFW_NOT_ALLOWED_CURSOR);

#if defined(__APPLE__)
  if (!initAngleForWindow(error)) return false;
#else
  glfwMakeContextCurrent(window_);
#if defined(_WIN32)
  if (!LoadWinGl()) return fail("GLES entry points unresolved (libGLESv2.dll)");
#endif
#endif

  rni::glvalidation::Install(&ProcAddr, nullptr);  // FP-05
  rni::image::SetMaxTextureSize(rni::gllimits::MaxTextureSize(&ProcAddr, nullptr));  // FP-16
  rni::contextflags::ApplyBeforeCreate();  // FP-22
  context_ = ImpellerContextCreateOpenGLESNew(IMPELLER_VERSION, &ProcAddr, nullptr);
  rni::contextflags::Report(context_);
  if (!context_) return fail("ImpellerContextCreateOpenGLESNew returned null");

  // fbo id 0 — the window's OWN default framebuffer, not one we allocate.
  // See the file comment: this is the one real difference from
  // HeadlessSurface, which must build its own texture+FBO because it has no
  // window to draw into. True on darwin too: ANGLE's window surface presents
  // through framebuffer 0 just as a GLX/EGL window surface does.
  ImpellerISize size = {width_, height_};
  surface_ = ImpellerSurfaceCreateWrappedFBONew(
      context_, 0u, kImpellerPixelFormatRGBA8888, &size);
  if (!surface_) return fail("ImpellerSurfaceCreateWrappedFBONew returned null");

  typography_ = ImpellerTypographyContextNew();
  if (!typography_) return fail("ImpellerTypographyContextNew returned null");

  std::printf("rn-impeller: GL_RENDERER=%s\n", (const char*)glGetString(GL_RENDERER));
  // ⛔ REPORT WHAT GL GRANTED, NOT WHAT WE ASKED FOR. GLFW_SAMPLES is a HINT:
  // a driver may silently hand back a single-sample config, and then "MSAA
  // changed nothing" and "MSAA was never enabled" are the same observation.
  // GL_SAMPLES on the live default framebuffer is the only honest number, and
  // it is what turns a null result into evidence.
  if (std::getenv("RNI_GLFW_SAMPLES") != nullptr) {
    GLint granted = 0;
    glGetIntegerv(GL_SAMPLES, &granted);
    std::printf("rn-impeller: glfw_samples_granted=%d\n", (int)granted);
  }
  std::fflush(stdout);
  return true;
}

// Reallocates the Impeller surface for the framebuffer's CURRENT size and
// re-records both sizes, so backingScale() and width()/height() describe the
// window that exists now rather than the one that opened.
//
// ⛔ THE IMPELLER SURFACE WRAPS A SIZE, NOT JUST AN FBO ID.
// FBO 0 stays valid across a resize -- it is the window's own default
// framebuffer -- but the ImpellerSurface built over it in init() carries the
// dimensions it was created with. Leaving it alone means Impeller keeps
// clipping and presenting at the OLD pixel size into a window that is now a
// different size, which reads as content pinned to a corner with garbage
// beside it. So the wrapper is released and rebuilt; the CONTEXT is not
// touched, because recreating that would drop every uploaded texture and the
// typography atlas for what is a per-drag event.
bool GlfwSurface::consumeDirty() {
  if (!dirty_.exchange(false, std::memory_order_acq_rel)) return false;
  if (!window_) return false;

#if defined(__APPLE__)
  // ⛔ RE-ASSERT THE LAYER SCALE BEFORE READING THE FRAMEBUFFER, NOT AFTER.
  // ENG item 2 (Retina scale drops to 1.00 after the first resize). On a live
  // resize AppKit resets the ANGLE CAMetalLayer's contentsScale back to 1.0
  // BEFORE this callback runs, so glfwGetFramebufferSize then reports the 1x
  // point size (px==points, scale=1.00) on a 2x display -- the "rough icons /
  // text after resize" read. Setting contentsScale back to backingScaleFactor
  // first restores the 2x drawable, so the framebuffer query below reports the
  // true 2x pixel size and width_/height_ carry the physical backing again.
  // The old code set the scale AFTER the query, one frame too late.
  GlfwCocoaSetLayerScale(window_);
#endif

  int fbWidth = 0, fbHeight = 0;
  glfwGetFramebufferSize(window_, &fbWidth, &fbHeight);
  int winWidth = 0, winHeight = 0;
  glfwGetWindowSize(window_, &winWidth, &winHeight);
  // A minimised window reports 0 in at least one axis on every platform. Zero
  // would divide the layout to nothing and ImpellerSurfaceCreateWrappedFBONew
  // would be asked for a degenerate surface, so drop the event and keep the
  // last good size; the un-minimise fires the callback again.
  if (fbWidth <= 0 || fbHeight <= 0 || winWidth <= 0 || winHeight <= 0)
    return false;
  if (fbWidth == width_ && fbHeight == height_ && winWidth == pointWidth_ &&
      winHeight == pointHeight_)
    return false;

  width_ = fbWidth;
  height_ = fbHeight;
  pointWidth_ = winWidth;
  pointHeight_ = winHeight;

  // ANGLE's window surface tracks the CALayer, which AppKit has already
  // resized by the time this callback runs, so there is nothing to rebuild on
  // the EGL side. The viewport is ours and must follow. contentsScale was
  // already re-asserted at the TOP of this function (before the framebuffer
  // query) so the drawable is 2x again; do NOT re-assert here.
  glViewport(0, 0, width_, height_);

  if (surface_) {
    ImpellerSurfaceRelease(surface_);
    surface_ = nullptr;
  }
  ImpellerISize size = {width_, height_};
  surface_ = ImpellerSurfaceCreateWrappedFBONew(
      context_, 0u, kImpellerPixelFormatRGBA8888, &size);
  return surface_ != nullptr;
}

void GlfwSurface::setRefreshHandler(std::function<void()> handler) {
  refreshHandler_ = std::move(handler);
}

void GlfwSurface::setMouseButtonHandler(
    std::function<void(float, float, bool)> handler) {
  mouseButtonHandler_ = std::move(handler);
}

void GlfwSurface::setExtraButtonHandler(
    std::function<void(const ExtraButtonEvent&)> handler) {
  extraButtonHandler_ = std::move(handler);
}

namespace {
// W3C `buttons` bit for a W3C `button` value: 0 left->1, 1 middle->4,
// 2 right->2, 3 back->8, 4 forward->16.
int ButtonsBitFor(int w3cButton) {
  switch (w3cButton) {
    case 0: return 1;
    case 1: return 4;
    case 2: return 2;
    case 3: return 8;
    case 4: return 16;
    default: return 0;
  }
}
}  // namespace

void GlfwSurface::dispatchExtraButton(double screenX, double screenY,
                                      bool down, int w3cButton, int glfwMods) {
  if (w3cButton < 1 || w3cButton > 4) return;
  lastMods_.shift = (glfwMods & GLFW_MOD_SHIFT) != 0;
  lastMods_.ctrl = (glfwMods & GLFW_MOD_CONTROL) != 0;
  lastMods_.alt = (glfwMods & GLFW_MOD_ALT) != 0;
  lastMods_.meta = (glfwMods & GLFW_MOD_SUPER) != 0;
  const int bit = ButtonsBitFor(w3cButton);
  ExtraClickState& st = extraClick_[w3cButton];
  if (down) {
    heldButtons_ |= bit;
    const double nowMs =
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count();
    const bool near =
        std::fabs(screenX - st.lastPressX) <= kMultiClickSlopPx &&
        std::fabs(screenY - st.lastPressY) <= kMultiClickSlopPx;
    st.clickCount =
        (near && nowMs - st.lastPressMs <= kMultiClickMs) ? st.clickCount + 1
                                                          : 1;
    st.lastPressMs = nowMs;
    st.lastPressX = screenX;
    st.lastPressY = screenY;
  } else {
    heldButtons_ &= ~bit;
  }
  if (!extraButtonHandler_) return;
  int fbW = 0, fbH = 0, winW = 0, winH = 0;
  if (window_) {
    glfwGetFramebufferSize(window_, &fbW, &fbH);
    glfwGetWindowSize(window_, &winW, &winH);
  }
  ExtraButtonEvent ev;
  ev.x = CursorPointsFromScreen(screenX, fbW, winW, pointScale_);
  ev.y = CursorPointsFromScreen(screenY, fbH, winH, pointScale_);
  ev.down = down;
  ev.button = w3cButton;
  ev.buttons = heldButtons_;
  ev.clickCount = st.clickCount < 1 ? 1 : st.clickCount;
  ev.shift = lastMods_.shift;
  ev.ctrl = lastMods_.ctrl;
  ev.alt = lastMods_.alt;
  ev.meta = lastMods_.meta;
  extraButtonHandler_(ev);
}

// item 6. The ONE routing point for a W3C button, shared by the real GLFW
// callback and synthesiseMouseButton, so the darwin Ctrl+left remap is
// exercised by the synthetic hook too.
void GlfwSurface::routeButton(double screenX, double screenY, bool down,
                              int w3cButton, int glfwMods) {
#if defined(__APPLE__)
  // macOS: Ctrl+left is the secondary (right) click. The release must
  // follow its press to the right-button path even if Ctrl was let go.
  if (w3cButton == 0) {
    if (down) ctrlLeftIsRight_ = (glfwMods & GLFW_MOD_CONTROL) != 0;
    if (ctrlLeftIsRight_) {
      w3cButton = 2;
      if (!down) ctrlLeftIsRight_ = false;
    }
  }
#endif
  if (w3cButton == 0) {
    // item 4b: mods carry Shift for Shift+click selection extension.
    dispatchCursorPoint(screenX, screenY, down, glfwMods);
  } else {
    dispatchExtraButton(screenX, screenY, down, w3cButton, glfwMods);
  }
}

void GlfwSurface::synthesiseMouseButton(int w3cButton, bool down,
                                        double screenX, double screenY,
                                        bool shift, bool ctrl, bool alt,
                                        bool meta) {
  const int mods = (shift ? GLFW_MOD_SHIFT : 0) |
                   (ctrl ? GLFW_MOD_CONTROL : 0) | (alt ? GLFW_MOD_ALT : 0) |
                   (meta ? GLFW_MOD_SUPER : 0);
  routeButton(screenX, screenY, down, w3cButton, mods);
}

void GlfwSurface::dispatchCursorPoint(double screenX, double screenY,
                                      bool down, int glfwMods) {
  // item 6: the LEFT button's share of the shared held-button mask and the
  // live modifier state, updated before any handler reads them.
  lastMods_.shift = (glfwMods & GLFW_MOD_SHIFT) != 0;
  lastMods_.ctrl = (glfwMods & GLFW_MOD_CONTROL) != 0;
  lastMods_.alt = (glfwMods & GLFW_MOD_ALT) != 0;
  lastMods_.meta = (glfwMods & GLFW_MOD_SUPER) != 0;
  if (down) {
    heldButtons_ |= 1;
  } else {
    heldButtons_ &= ~1;
  }
  if (!mouseButtonHandler_) return;
  // item 4b: count multi-clicks on the PRESS, before the handler reads it.
  if (down) {
    const double nowMs =
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count();
    const bool near = std::fabs(screenX - lastPressX_) <= kMultiClickSlopPx &&
                      std::fabs(screenY - lastPressY_) <= kMultiClickSlopPx;
    clickCount_ =
        (near && nowMs - lastPressMs_ <= kMultiClickMs) ? clickCount_ + 1 : 1;
    lastPressMs_ = nowMs;
    lastPressX_ = screenX;
    lastPressY_ = screenY;
    pressShift_ = (glfwMods & GLFW_MOD_SHIFT) != 0;
  }
  // ⛔ RE-READ THE SIZES, DO NOT USE THE CACHED width_/pointWidth_.
  // Those are refreshed by consumeDirty(), which the frame loop calls. During
  // a macOS modal resize drag the loop is blocked, so a click that arrives
  // just after a resize would be converted with the PREVIOUS geometry — a
  // silent off-by-a-resize that only manifests as "the first click after
  // resizing hits the wrong thing". Querying GLFW costs two syscall-free
  // reads of cached window state and removes the ordering dependency
  // entirely.
  int fbW = 0, fbH = 0, winW = 0, winH = 0;
  if (window_) {
    glfwGetFramebufferSize(window_, &fbW, &fbH);
    glfwGetWindowSize(window_, &winW, &winH);
  }
  const float px = CursorPointsFromScreen(screenX, fbW, winW, pointScale_);
  const float py = CursorPointsFromScreen(screenY, fbH, winH, pointScale_);
  mouseButtonHandler_(px, py, down);
}

void GlfwSurface::setScrollHandler(
    std::function<void(float, float, float, float)> handler) {
  scrollHandler_ = std::move(handler);
}

// <ScrollView>. ENG-02. The one place screen->points AND the GLFW sign flip
// happen; see the header for why the flip is not optional.
void GlfwSurface::dispatchScrollPoint(double screenX, double screenY,
                                      double glfwDx, double glfwDy) {
  if (!scrollHandler_) return;
  // Re-read the sizes for the same reason dispatchCursorPoint does: the cached
  // values are refreshed by the frame loop, which is blocked during a modal
  // resize drag.
  int fbW = 0, fbH = 0, winW = 0, winH = 0;
  if (window_) {
    glfwGetFramebufferSize(window_, &fbW, &fbH);
    glfwGetWindowSize(window_, &winW, &winH);
  }
  const float px = CursorPointsFromScreen(screenX, fbW, winW, pointScale_);
  const float py = CursorPointsFromScreen(screenY, fbH, winH, pointScale_);
  // Wheel notches are not points. A notch of 1 that moved the list by one point
  // would be indistinguishable from a dead scroll to a human, so it is scaled
  // to a conventional line height. Both signs flip here: GLFW positive-y = wheel
  // away = scroll UP, RN contentOffset grows going DOWN; GLFW positive-x = push
  // right, RN contentOffset grows going RIGHT. dx is carried through with the
  // same treatment dy gets rather than dropped, which is the whole fix -- a
  // y-only handler could never move a horizontal list.
  constexpr float kPointsPerNotch = 40.0f;
  scrollHandler_(px, py, (float)(-glfwDx) * kPointsPerNotch,
                 (float)(-glfwDy) * kPointsPerNotch);
}

void GlfwSurface::synthesiseScroll(double screenX, double screenY, double dx,
                                   double dy) {
  // Through dispatchScrollPoint, NOT scrollHandler_ directly, so the probe
  // exercises the same conversion and the same sign flip a real wheel does. A
  // synthetic path that called the handler with raw numbers would pass while
  // the real wheel scrolled backwards.
  dispatchScrollPoint(screenX, screenY, dx, dy);
}

void GlfwSurface::setHoverHandler(std::function<int(float, float)> handler) {
  hoverHandler_ = std::move(handler);
}

void GlfwSurface::setCursorLeaveHandler(std::function<void()> handler) {
  cursorLeaveHandler_ = std::move(handler);
}

// <TextInput>. ENG-01b. Keyboard handler setters.
void GlfwSurface::setCharHandler(std::function<void(unsigned int)> handler) {
  charHandler_ = std::move(handler);
}
void GlfwSurface::setKeyHandler(
    std::function<void(EditKey, bool)> handler) {
  keyHandler_ = std::move(handler);
}
void GlfwSurface::setFullKeyHandler(
    std::function<void(const KeyEvent&)> handler) {
  fullKeyHandler_ = std::move(handler);
}

// desktop-input-gap P0 item 1. THE ONE PLACE A GLFW KEY TUPLE BECOMES A
// KeyEvent, shared by the real glfwSetKeyCallback and synthesiseKey() below
// -- exactly the discipline dispatchCursorPoint/dispatchScrollPoint already
// use for clicks and scroll, so a synthetic gate exercises the identical
// table a real keypress does rather than a parallel copy that could drift.
void GlfwSurface::dispatchKeyEvent(int key, int scancode, int action,
                                   int mods) {
  std::string w3cKey, w3cCode;
  if (!TranslateGlfwKey(key, scancode, &w3cKey, &w3cCode)) return;

  KeyEvent ev;
  ev.key = w3cKey;
  ev.code = w3cCode;
  ev.phase = action == GLFW_RELEASE ? KeyPhase::Up
            : action == GLFW_REPEAT ? KeyPhase::Repeat
                                     : KeyPhase::Down;
  ev.shift = (mods & GLFW_MOD_SHIFT) != 0;
  ev.ctrl = (mods & GLFW_MOD_CONTROL) != 0;
  ev.alt = (mods & GLFW_MOD_ALT) != 0;
  ev.meta = (mods & GLFW_MOD_SUPER) != 0;
  ev.capsLock = (mods & GLFW_MOD_CAPS_LOCK) != 0;
  ev.scancode = scancode;

  if (fullKeyHandler_) fullKeyHandler_(ev);

  // Backward-compatible editing path: Backspace/Enter on Down/Repeat only,
  // BYTE-IDENTICAL to the pre-existing behaviour (release was never an edit,
  // and no other key was ever forwarded here) so ci-textedit.sh needs no
  // changes and stays the regression guard for this exact path.
  if (keyHandler_ && ev.phase != KeyPhase::Up) {
    if (key == GLFW_KEY_BACKSPACE) {
      keyHandler_(EditKey::Backspace, ev.shift);
    } else if (key == GLFW_KEY_ENTER || key == GLFW_KEY_KP_ENTER) {
      keyHandler_(EditKey::Enter, ev.shift);
    }
  }
}

// Synthesises a key event by W3C name through the SAME dispatchKeyEvent the
// real callback uses, converting the neutral KeyMods into the GLFW_MOD_*
// bitmask HERE -- the only place outside dispatchKeyEvent itself that is
// allowed to know the bit values -- so main.cpp's CLI test hooks never name
// a GLFW symbol, matching the encapsulation the rest of this class keeps.
bool GlfwSurface::synthesiseKey(const std::string& key, KeyPhase phase,
                                const KeyMods& mods) {
  int glfwKey = 0;
  if (!GlfwKeyFromName(key, &glfwKey)) return false;
  int glfwMods = 0;
  if (mods.shift) glfwMods |= GLFW_MOD_SHIFT;
  if (mods.ctrl) glfwMods |= GLFW_MOD_CONTROL;
  if (mods.alt) glfwMods |= GLFW_MOD_ALT;
  if (mods.meta) glfwMods |= GLFW_MOD_SUPER;
  if (mods.capsLock) glfwMods |= GLFW_MOD_CAPS_LOCK;
  const int action = phase == KeyPhase::Up ? GLFW_RELEASE
                    : phase == KeyPhase::Repeat ? GLFW_REPEAT
                                                 : GLFW_PRESS;
  const int scancode = glfwGetKeyScancode(glfwKey);
  dispatchKeyEvent(glfwKey, scancode, action, glfwMods);
  return true;
}

// desktop-input-gap item 2a. Synthesises a character event with NO GLFW
// translation at all -- charHandler_ already takes a decoded codepoint, so
// this is a direct call, the same "identical path, zero parallel logic"
// discipline synthesiseKey keeps for dispatchKeyEvent.
bool GlfwSurface::synthesiseChar(unsigned int codepoint) {
  if (!charHandler_) return false;
  charHandler_(codepoint);
  return true;
}

// ENG-09 hover/cursor. The one place a hover's screen->points conversion
// happens; see the header. Applies the cursor shape the handler resolved so
// the shape decision rides with the hit test rather than being recomputed.
void GlfwSurface::dispatchHoverPoint(double screenX, double screenY) {
  if (!hoverHandler_) return;
  // Re-read the sizes for the same reason dispatchCursorPoint does: the cached
  // values are refreshed by the frame loop, which is blocked during a modal
  // resize drag, and a hover that arrives just after a resize must use the
  // geometry that exists now.
  int fbW = 0, fbH = 0, winW = 0, winH = 0;
  if (window_) {
    glfwGetFramebufferSize(window_, &fbW, &fbH);
    glfwGetWindowSize(window_, &winW, &winH);
  }
  const float px = CursorPointsFromScreen(screenX, fbW, winW, pointScale_);
  const float py = CursorPointsFromScreen(screenY, fbH, winH, pointScale_);
  const int kind = hoverHandler_(px, py);
  applyCursorKind(kind);
}

// ENG-09 hover/cursor. Set the window cursor for `kind`, skipping the GLFW
// call when it is already that shape so a per-move stream does not thrash it.
void GlfwSurface::applyCursorKind(int kind) {
  if (kind == appliedCursorKind_) return;
  if (!window_) return;
#if defined(__APPLE__)
  // ENG item 6. GLFW has no grab shape, so kinds 3 (grab / open hand) and 4
  // (grabbing / closed hand) go straight to NSCursor on darwin. On other
  // platforms these fall through to arrow below (no grab standard cursor), the
  // same graceful degrade a null standard cursor gets.
  if (kind == 3 || kind == 4) {
    GlfwCocoaSetGrabCursor(window_, /*grabbing=*/kind == 4);
    appliedCursorKind_ = kind;
    return;
  }
#endif
  GLFWcursor* c = arrowCursor_;
  if (kind == rni::kCursorHand || kind == rni::kCursorGrab ||
      kind == rni::kCursorGrabbing) {
    c = handCursor_;  // GLFW has no grab shape off darwin
  } else if (kind == rni::kCursorIBeam) {
    c = ibeamCursor_;
  } else if (kind > 0 && kind < rni::kCursorKindCount && shapeCursors_[kind]) {
    c = shapeCursors_[kind];
  }
  // A null standard cursor (platform did not provide the shape) means "leave
  // the current cursor alone" rather than resetting to the platform default,
  // which would flicker to arrow over a hand-requesting view on such a host.
  if (!c) return;
  glfwSetCursor(window_, c);
  appliedCursorKind_ = kind;
  // Name the cursor object actually handed to GLFW, not the requested kind.
  int shown = rni::kCursorArrow;
  if (c == handCursor_) shown = rni::kCursorHand;
  else if (c == ibeamCursor_) shown = rni::kCursorIBeam;
  for (int k = 0; k < rni::kCursorKindCount; ++k) {
    if (shapeCursors_[k] && c == shapeCursors_[k]) shown = k;
  }
  printf("rn-impeller: cursor_applied=%s\n", rni::CursorKindName(shown));
  fflush(stdout);
}

void GlfwSurface::synthesiseHover(double screenX, double screenY) {
  // Through dispatchHoverPoint, NOT hoverHandler_ directly, so the probe
  // exercises the same conversion and the same cursor-apply a real move does.
  dispatchHoverPoint(screenX, screenY);
}

void GlfwSurface::synthesiseCursorLeave() {
  if (cursorLeaveHandler_) cursorLeaveHandler_();
  applyCursorKind(0);
}

void GlfwSurface::synthesiseMouse(int op, double screenX, double screenY,
                                  bool shift) {
  if (op == 2) {
    dispatchHoverPoint(screenX, screenY);
    return;
  }
  dispatchCursorPoint(screenX, screenY, op == 0, shift ? GLFW_MOD_SHIFT : 0);
}

void GlfwSurface::synthesiseClick(double screenX, double screenY) {
  // Down then up, in that order, through the SAME conversion the callback
  // uses. RN's Pressability needs both: a lone down highlights and never
  // fires onPress.
  dispatchCursorPoint(screenX, screenY, true);
  dispatchCursorPoint(screenX, screenY, false);
}

void GlfwSurface::requestSize(int pointW, int pointH) {
  if (!window_ || pointW <= 0 || pointH <= 0) return;
  glfwSetWindowSize(window_, pointW, pointH);
}

bool GlfwSurface::drawDisplayList(ImpellerDisplayList dl) {
  if (!ImpellerSurfaceDrawDisplayList(surface_, dl)) return false;
  glFinish();
  return true;
}

bool GlfwSurface::readPixels(std::vector<Px>* out) {
  std::vector<Px> raw((size_t)width_ * height_);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glReadPixels(0, 0, width_, height_, GL_RGBA, GL_UNSIGNED_BYTE, raw.data());
  if (glGetError() != GL_NO_ERROR) return false;
  out->resize(raw.size());
  // Same Y-flip as HeadlessSurface::readPixels — glReadPixels' origin is
  // bottom-left, Impeller draws top-left.
  for (int y = 0; y < height_; ++y) {
    for (int x = 0; x < width_; ++x) {
      (*out)[(size_t)y * width_ + x] = raw[(size_t)(height_ - 1 - y) * width_ + x];
    }
  }
  return true;
}

void GlfwSurface::pollEvents() { glfwPollEvents(); }

void GlfwSurface::waitEvents(double timeoutSeconds) {
  if (timeoutSeconds <= 0.0) return;
  glfwWaitEventsTimeout(timeoutSeconds);
}

// P12-01: wake a thread parked in glfwWaitEventsTimeout. glfwPostEmptyEvent is
// documented safe to call from ANY thread, which is exactly what the damage
// wake needs: the JS thread's applyMutations/updateViewProps fires this so a
// commit while the loop sleeps repaints promptly instead of stalling to the
// next unrelated input.
void GlfwSurface::postEmptyEvent() { glfwPostEmptyEvent(); }

// item 5. See the header: MAIN-THREAD ONLY. glfwGetClipboardString returns a
// pointer owned by GLFW (valid until the next clipboard call or window
// destruction), so it is copied into a std::string before returning rather
// than handed back raw.
std::string GlfwSurface::getClipboardString() const {
  if (!window_) return std::string();
  const char* s = glfwGetClipboardString(window_);
  return s ? std::string(s) : std::string();
}

void GlfwSurface::setClipboardString(const std::string& s) {
  if (!window_) return;
  glfwSetClipboardString(window_, s.c_str());
}

bool GlfwSurface::shouldClose() const {
  return window_ ? glfwWindowShouldClose(window_) : true;
}

void GlfwSurface::present() {
#if defined(__APPLE__)
  // glfwSwapBuffers is a NO-OP for a GLFW_NO_API window — GLFW has no context
  // to swap. The swap belongs to the EGL surface we created.
  eglSwapBuffers(display_, eglSurface_);
#else
  glfwSwapBuffers(window_);
#endif
}

}  // namespace rni
