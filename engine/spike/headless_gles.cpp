// P0 spike: prove Impeller renders, headless, with NO window system.
// Surfaceless EGL (llvmpipe/swrast ok) -> GLES3 FBO -> ImpellerSurfaceCreateWrappedFBONew
// -> DisplayList -> glReadPixels -> assert real colors at known coordinates.
//
// This is the CI pixel-gate mechanism for the whole program, not just a demo.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "impeller.h"

static const int W = 400, H = 300;

static void* ProcAddr(const char* name, void*) {
  return (void*)eglGetProcAddress(name);
}

#define CHECK(cond, msg) do { if (!(cond)) { fprintf(stderr, "FAIL: %s\n", msg); return 1; } } while (0)

struct Px { unsigned char r, g, b, a; };

int main() {
  printf("impeller header version: %d.%d.%d\n", IMPELLER_VERSION_VARIANT,
         IMPELLER_VERSION_MAJOR, IMPELLER_VERSION_MINOR);

  // ---- 1. Surfaceless EGL context (no X11, no Wayland, no GLFW) ----
  // EGL_DEFAULT_DISPLAY needs a display server; EGL_PLATFORM_SURFACELESS_MESA
  // does not. This is what makes the pixel gate runnable in CI containers.
  auto getPlatformDisplay = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
      "eglGetPlatformDisplayEXT");
  CHECK(getPlatformDisplay != nullptr, "eglGetPlatformDisplayEXT unavailable");
  EGLDisplay dpy = getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                                      EGL_DEFAULT_DISPLAY, nullptr);
  CHECK(dpy != EGL_NO_DISPLAY, "surfaceless eglGetPlatformDisplay");
  EGLint major = 0, minor = 0;
  CHECK(eglInitialize(dpy, &major, &minor), "eglInitialize");
  printf("EGL %d.%d vendor=%s\n", major, minor, eglQueryString(dpy, EGL_VENDOR));

  const EGLint cfg_attrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                              EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                              EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                              EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg; EGLint n = 0;
  CHECK(eglChooseConfig(dpy, cfg_attrs, &cfg, 1, &n) && n == 1, "eglChooseConfig");
  CHECK(eglBindAPI(EGL_OPENGL_ES_API), "eglBindAPI");
  const EGLint ctx_attrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
  EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
  CHECK(ctx != EGL_NO_CONTEXT, "eglCreateContext");
  CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx), "eglMakeCurrent surfaceless");
  printf("GL_RENDERER=%s\n", (const char*)glGetString(GL_RENDERER));

  // ---- 2. FBO we own ----
  GLuint tex = 0, fbo = 0;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
  CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "FBO incomplete");

  // ---- 3. Impeller context on our GLES context ----
  uint32_t lib_version = ImpellerGetVersion();
  printf("libimpeller runtime version: %u (header %u)\n", lib_version, IMPELLER_VERSION);
  ImpellerContext ictx = ImpellerContextCreateOpenGLESNew(IMPELLER_VERSION, &ProcAddr, nullptr);
  CHECK(ictx != nullptr, "ImpellerContextCreateOpenGLESNew returned null");

  ImpellerISize size = {W, H};
  ImpellerSurface surface = ImpellerSurfaceCreateWrappedFBONew(
      ictx, fbo, kImpellerPixelFormatRGBA8888, &size);
  CHECK(surface != nullptr, "ImpellerSurfaceCreateWrappedFBONew returned null");

  // ---- 4. Draw: white bg, red rect left, green rounded rect right, blue circle bottom ----
  ImpellerDisplayListBuilder builder = ImpellerDisplayListBuilderNew(nullptr);
  CHECK(builder != nullptr, "DisplayListBuilderNew");
  ImpellerPaint paint = ImpellerPaintNew();

  ImpellerColor white = {1.0f, 1.0f, 1.0f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &white);
  ImpellerRect full = {0, 0, (float)W, (float)H};
  ImpellerDisplayListBuilderDrawRect(builder, &full, paint);

  ImpellerColor red = {1.0f, 0.0f, 0.0f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &red);
  ImpellerRect r1 = {20, 20, 100, 100};   // x,y,w,h
  ImpellerDisplayListBuilderDrawRect(builder, &r1, paint);

  ImpellerColor green = {0.0f, 1.0f, 0.0f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &green);
  ImpellerRect r2 = {200, 20, 150, 100};
  ImpellerRoundingRadii radii = {};
  radii.top_left = {20, 20}; radii.top_right = {20, 20};
  radii.bottom_left = {20, 20}; radii.bottom_right = {20, 20};
  ImpellerDisplayListBuilderDrawRoundedRect(builder, &r2, &radii, paint);

  ImpellerColor blue = {0.0f, 0.0f, 1.0f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &blue);
  ImpellerRect oval = {150, 170, 100, 100};
  ImpellerDisplayListBuilderDrawOval(builder, &oval, paint);

  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(builder);
  CHECK(dl != nullptr, "CreateDisplayListNew");
  CHECK(ImpellerSurfaceDrawDisplayList(surface, dl), "SurfaceDrawDisplayList returned false");
  glFinish();

  // ---- 5. Read back and ASSERT actual pixels ----
  std::vector<Px> buf(W * H);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, buf.data());
  CHECK(glGetError() == GL_NO_ERROR, "glReadPixels");

  // glReadPixels origin is bottom-left; Impeller draws top-left. Flip y for sampling.
  auto at = [&](int x, int y_topleft) -> Px { return buf[(H - 1 - y_topleft) * W + x]; };

  struct Probe { const char* name; int x, y; unsigned char r, g, b; };
  Probe probes[] = {
      {"red rect center",     70,  70, 255,   0,   0},
      {"green rrect center", 275,  70,   0, 255,   0},
      {"blue oval center",   200, 220,   0,   0, 255},
      {"white bg",           380, 150, 255, 255, 255},
      {"rrect corner cut",   202,  22, 255, 255, 255},  // rounded => bg shows through
  };
  int fails = 0;
  for (auto& p : probes) {
    Px px = at(p.x, p.y);
    bool ok = abs((int)px.r - p.r) <= 8 && abs((int)px.g - p.g) <= 8 && abs((int)px.b - p.b) <= 8;
    printf("%-20s (%3d,%3d) got=(%3d,%3d,%3d) want=(%3d,%3d,%3d) %s\n", p.name, p.x, p.y,
           px.r, px.g, px.b, p.r, p.g, p.b, ok ? "OK" : "MISMATCH");
    if (!ok) fails++;
  }

  // Distinct-color count: guards against a uniform/blank frame passing by luck.
  int distinct = 0;
  {
    std::vector<unsigned> seen;
    for (auto& p : buf) {
      unsigned k = (p.r << 16) | (p.g << 8) | p.b;
      bool found = false;
      for (auto s : seen) if (s == k) { found = true; break; }
      if (!found && seen.size() < 4096) seen.push_back(k);
    }
    distinct = (int)seen.size();
  }
  printf("distinct colors: %d\n", distinct);
  if (distinct < 4) { fprintf(stderr, "FAIL: frame too uniform (%d colors)\n", distinct); fails++; }

  // Write a PPM so a human can look at it.
  FILE* f = fopen("/tmp/impeller-spike.ppm", "wb");
  fprintf(f, "P6\n%d %d\n255\n", W, H);
  for (int y = H - 1; y >= 0; --y)
    for (int x = 0; x < W; ++x) { Px p = buf[y * W + x]; fwrite(&p, 1, 3, f); }
  fclose(f);
  printf("wrote /tmp/impeller-spike.ppm\n");

  ImpellerDisplayListRelease(dl);
  ImpellerPaintRelease(paint);
  ImpellerDisplayListBuilderRelease(builder);
  ImpellerSurfaceRelease(surface);
  ImpellerContextRelease(ictx);

  if (fails) { printf("IMPELLER_SPIKE_FAIL (%d)\n", fails); return 1; }
  printf("IMPELLER_SPIKE_PASS\n");
  return 0;
}
