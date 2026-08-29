// P10-A bench: can this engine carry the game view's canvas draw path, and how
// fast? The macOS tester instrumented CanvasRenderingContext2D on the real game
// and measured the whole API surface it uses -- SIX operations:
//
//   fillRect, drawImage, clearRect, save, restore, translate
//   plus globalAlpha and imageSmoothingEnabled as state
//
// Zero paths, zero gradients, zero text, zero clips. So the question is NOT
// "implement canvas on Impeller". It is "do the rect-fill and textured-quad
// primitives already here compose into that, and do they survive ~290 draws a
// frame". This measures both rather than reasoning about it.
//
// ⛔ WHY AN OFFSCREEN TARGET IS THE INTERESTING PART. Impeller's C API has NO
// render-to-texture entry point -- there is no ImpellerSurfaceCreateOffscreen.
// The only surface constructors are WrappedFBO, WrappedMetalDrawable, and the
// swapchain one. The game bakes its sprites into 3 offscreen canvases once and
// then blits them 128454 times, so "no offscreen" would have killed the design.
// It is reachable anyway, by owning the GL texture ourselves:
//
//   our FBO -> ImpellerSurfaceCreateWrappedFBONew -> draw the atlas
//           -> ImpellerTextureGetOpenGLHandle-style adoption via
//              ImpellerTextureCreateWithOpenGLTextureHandleNew
//           -> ImpellerDisplayListBuilderDrawTextureRect on the main surface
//
// That is exactly canvas's createElement('canvas') + drawImage, with no image
// FILE decoding anywhere in it -- which is the expensive dependency this engine
// does not have and, for this game, does not need.
//
// ⛔ THE NEGATIVE CONTROL IS NOT OPTIONAL. RNI_SKIP_BLIT=1 renders the same
// frame with the blit removed. The blit-site probes must come back BACKGROUND.
// Without that, "the sprite is there" passes on an engine that draws the atlas
// nowhere and leaves a coincidentally-coloured fillRect underneath -- and this
// game has already shipped a green "it rendered" over a wrong screen twice.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>

#include "impeller.h"

namespace {

constexpr int W = 400, H = 300;
constexpr int ATLAS = 64;

struct Px { unsigned char r, g, b, a; };

void* ProcAddr(const char* name, void*) {
  return reinterpret_cast<void*>(eglGetProcAddress(name));
}

int envInt(const char* k, int fallback) {
  const char* v = getenv(k);
  return v && *v ? atoi(v) : fallback;
}

ImpellerColor Rgba(float r, float g, float b, float a = 1.0f) {
  return ImpellerColor{r, g, b, a, kImpellerColorSpaceSRGB};
}

void FillRect(ImpellerDisplayListBuilder b, ImpellerPaint p, ImpellerColor c,
              float x, float y, float w, float h) {
  ImpellerPaintSetColor(p, &c);
  ImpellerRect r{x, y, w, h};
  ImpellerDisplayListBuilderDrawRect(b, &r, p);
}

}  // namespace

#define CHECK(cond, msg)                          \
  do {                                            \
    if (!(cond)) {                                \
      fprintf(stderr, "CANVAS_BENCH_FAIL: %s\n", msg); \
      return 1;                                   \
    }                                             \
  } while (0)

int main() {
  const bool skipBlit = envInt("RNI_SKIP_BLIT", 0) != 0;
  const int steadyRects = envInt("RNI_RECTS", 290);    // measured median
  const int burstRects = envInt("RNI_BURST", 9367);    // measured worst frame
  const int timedFrames = envInt("RNI_FRAMES", 120);

  // ---- EGL, surfaceless: same substrate every other gate in this repo uses --
  // ⛔ SURFACELESS_MESA IS A MESA EXTENSION, AND THE MAC DOES NOT HAVE IT.
  // The name says Mesa and it means it: on macOS the GLES driver is ANGLE, and
  // eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA) returns
  // EGL_NO_DISPLAY there. ANGLE does implement EGL_KHR_surfaceless_context, so
  // a PLAIN eglGetDisplay(EGL_DEFAULT_DISPLAY) followed by the same
  // eglMakeCurrent(EGL_NO_SURFACE, ...) works -- the surfacelessness comes
  // from the context, not from the platform enum. Try Mesa's spelling first
  // (Linux CI), fall back to the portable one (Mac).
  EGLDisplay dpy = EGL_NO_DISPLAY;
  const char* dpyPath = "surfaceless-mesa";
  auto getPlatformDisplay = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
      "eglGetPlatformDisplayEXT");
  if (getPlatformDisplay != nullptr) {
    dpy = getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                             (void*)(uintptr_t)EGL_DEFAULT_DISPLAY, nullptr);
  }
  if (dpy == EGL_NO_DISPLAY) {
    dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    dpyPath = "default-display";
  }
  CHECK(dpy != EGL_NO_DISPLAY, "surfaceless eglGetPlatformDisplay");
  EGLint maj = 0, min = 0;
  CHECK(eglInitialize(dpy, &maj, &min), "eglInitialize");
  const EGLint cfgAttrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                             EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                             EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                             EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg; EGLint n = 0;
  CHECK(eglChooseConfig(dpy, cfgAttrs, &cfg, 1, &n) && n == 1, "eglChooseConfig");
  CHECK(eglBindAPI(EGL_OPENGL_ES_API), "eglBindAPI");
  const EGLint ctxAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
  EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxAttrs);
  CHECK(ctx != EGL_NO_CONTEXT, "eglCreateContext");
  CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx), "eglMakeCurrent");
  printf("GL_RENDERER=%s (egl=%s)\n", (const char*)glGetString(GL_RENDERER),
         dpyPath);

  ImpellerContext ictx =
      ImpellerContextCreateOpenGLESNew(IMPELLER_VERSION, &ProcAddr, nullptr);
  CHECK(ictx != nullptr, "ImpellerContextCreateOpenGLESNew");

  auto makeFbo = [](int w, int h, GLuint* tex, GLuint* fbo) -> bool {
    glGenTextures(1, tex);
    glBindTexture(GL_TEXTURE_2D, *tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, nullptr);
    // imageSmoothingEnabled=false in the game: pixel art must not blur.
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glGenFramebuffers(1, fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, *fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           *tex, 0);
    return glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  };

  // ---- 1. Bake the sprite atlas into an OFFSCREEN target -------------------
  // Four asymmetric quadrants on purpose: a symmetric atlas cannot tell a
  // correct blit from a vertically flipped one, and GL's readback origin is
  // bottom-left while Impeller paints top-left. If this is flipped, the probe
  // below reports it as a flip rather than as a colour mismatch.
  GLuint atlasTex = 0, atlasFbo = 0;
  CHECK(makeFbo(ATLAS, ATLAS, &atlasTex, &atlasFbo), "atlas FBO incomplete");
  ImpellerISize atlasSize{ATLAS, ATLAS};
  ImpellerSurface atlasSurface = ImpellerSurfaceCreateWrappedFBONew(
      ictx, atlasFbo, kImpellerPixelFormatRGBA8888, &atlasSize);
  CHECK(atlasSurface != nullptr, "wrap atlas FBO");
  {
    ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
    ImpellerPaint p = ImpellerPaintNew();
    const float h = ATLAS / 2.0f;
    FillRect(b, p, Rgba(1, 0, 0), 0, 0, h, h);        // TL red
    FillRect(b, p, Rgba(0, 1, 0), h, 0, h, h);        // TR green
    FillRect(b, p, Rgba(0, 0, 1), 0, h, h, h);        // BL blue
    FillRect(b, p, Rgba(1, 1, 0), h, h, h, h);        // BR yellow
    ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);
    CHECK(dl != nullptr, "atlas display list");
    CHECK(ImpellerSurfaceDrawDisplayList(atlasSurface, dl), "atlas draw");
    glFinish();
    ImpellerDisplayListRelease(dl);
    ImpellerPaintRelease(p);
    ImpellerDisplayListBuilderRelease(b);
  }

  // Adopt the baked texture. Ownership transfers to Impeller, so the GL handle
  // must NOT be glDeleteTextures'd here -- that would be a double free.
  ImpellerTextureDescriptor desc{};
  desc.pixel_format = kImpellerPixelFormatRGBA8888;
  desc.size = atlasSize;
  desc.mip_count = 1;
  ImpellerTexture sprite =
      ImpellerTextureCreateWithOpenGLTextureHandleNew(ictx, &desc, atlasTex);
  CHECK(sprite != nullptr, "adopt atlas GL texture as ImpellerTexture");

  // ---- 2. Main surface ------------------------------------------------------
  GLuint mainTex = 0, mainFbo = 0;
  CHECK(makeFbo(W, H, &mainTex, &mainFbo), "main FBO incomplete");
  ImpellerISize mainSize{W, H};
  ImpellerSurface surface = ImpellerSurfaceCreateWrappedFBONew(
      ictx, mainFbo, kImpellerPixelFormatRGBA8888, &mainSize);
  CHECK(surface != nullptr, "wrap main FBO");

  // ⛔ A TEXTURE ADOPTED FROM AN FBO ARRIVES Y-FLIPPED, AND NOTHING REPORTS IT.
  //
  // GL's framebuffer origin is BOTTOM-left; Impeller's drawing origin is
  // TOP-left. When Impeller renders into a wrapped FBO it accounts for that on
  // the way out to the screen, but the raw GL texture behind that FBO is still
  // in GL's own orientation. Adopt it with
  // ImpellerTextureCreateWithOpenGLTextureHandleNew and DrawTextureRect samples
  // it as-is -- so the atlas blits upside down.
  //
  // Measured 2026-08-29 with the asymmetric 4-quadrant atlas below: the TL
  // probe came back BLUE (the bottom-left quadrant) and BL came back RED.
  // Every colour was a real painted colour and the frame looked entirely
  // plausible, which is exactly why a symmetric test atlas would have passed
  // this and shipped the flip. For pixel-art sprites drawn from an atlas, a
  // vertical flip is not subtle when you see it and invisible when you don't.
  //
  // Fixed here at the draw site: translate to the destination, scale y by -1,
  // and draw at negative height. Canvas's drawImage has no such flip, so this
  // correction belongs in the engine's blit path, NOT in game JS.
  auto blitSprite = [&](ImpellerDisplayListBuilder b, float dx, float dy,
                        ImpellerPaint paint) {
    ImpellerRect src{0, 0, ATLAS, ATLAS};
    ImpellerDisplayListBuilderSave(b);
    ImpellerDisplayListBuilderTranslate(b, dx, dy + ATLAS);
    ImpellerDisplayListBuilderScale(b, 1.0f, -1.0f);
    ImpellerRect dst{0, 0, ATLAS, ATLAS};
    ImpellerDisplayListBuilderDrawTextureRect(
        b, sprite, &src, &dst, kImpellerTextureSamplingNearestNeighbor, paint);
    ImpellerDisplayListBuilderRestore(b);
  };

  // One frame of the game's actual op mix. `extraRects` is the volume knob.
  auto renderFrame = [&](int extraRects, bool doBlit) {
    ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
    ImpellerPaint p = ImpellerPaintNew();

    FillRect(b, p, Rgba(1, 1, 1), 0, 0, W, H);           // clearRect
    FillRect(b, p, Rgba(1, 0, 0), 20, 20, 60, 60);       // plain fillRect

    // save + translate + restore, the way world-art.js composes a sprite.
    ImpellerDisplayListBuilderSave(b);
    ImpellerDisplayListBuilderTranslate(b, 100, 0);
    FillRect(b, p, Rgba(0, 0, 1), 20, 120, 60, 60);      // lands at x=120
    ImpellerDisplayListBuilderRestore(b);
    // If restore did not pop the translate, this lands at x=120 too and the
    // probe at (40,220) reads background instead of green.
    FillRect(b, p, Rgba(0, 0.6f, 0), 20, 200, 40, 40);

    if (doBlit) {
      ImpellerRect src{0, 0, ATLAS, ATLAS};
      blitSprite(b, 200, 20, nullptr);

      // globalAlpha: same blit, half opacity, over white.
      ImpellerPaint ap = ImpellerPaintNew();
      ImpellerColor mod = Rgba(1, 1, 1, 0.5f);
      ImpellerPaintSetColor(ap, &mod);
      blitSprite(b, 300, 120, ap);
      ImpellerPaintRelease(ap);
      (void)src;
    }

    // Volume: the steady-state rect storm, deterministic so frames are equal.
    for (int i = 0; i < extraRects; ++i) {
      float x = (float)((i * 37) % (W - 6));
      float y = (float)((i * 53) % (H - 6));
      FillRect(b, p, Rgba(((i * 7) % 255) / 255.0f, ((i * 11) % 255) / 255.0f,
                          ((i * 13) % 255) / 255.0f, 1.0f),
               x, y, 5, 5);
    }

    ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);
    bool ok = dl && ImpellerSurfaceDrawDisplayList(surface, dl);
    if (dl) ImpellerDisplayListRelease(dl);
    ImpellerPaintRelease(p);
    ImpellerDisplayListBuilderRelease(b);
    return ok;
  };

  // ---- 3. Correctness frame (no volume, so probes are unambiguous) ---------
  CHECK(renderFrame(0, !skipBlit), "correctness frame draw");
  glFinish();

  std::vector<Px> buf(W * H);
  glBindFramebuffer(GL_FRAMEBUFFER, mainFbo);
  glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, buf.data());
  CHECK(glGetError() == GL_NO_ERROR, "glReadPixels");
  auto at = [&](int x, int y) { return buf[(H - 1 - y) * W + x]; };

  struct Probe { const char* name; int x, y; int r, g, b; };
  // Blit-site expectations differ between the two runs BY DESIGN. That
  // difference is the gate: identical results would mean the blit drew nothing.
  const Probe probes[] = {
      {"fillRect",        50,  50, 255,   0,   0},
      {"translated rect",150, 150,   0,   0, 255},
      {"translate gap",   50, 150, 255, 255, 255},
      {"after restore",   40, 220,   0, 153,   0},
      {"background",     380, 280, 255, 255, 255},
      {"sprite TL",      216,  36, skipBlit ? 255 : 255, skipBlit ? 255 : 0,   skipBlit ? 255 : 0},
      {"sprite TR",      248,  36, skipBlit ? 255 : 0,   255,                  skipBlit ? 255 : 0},
      {"sprite BL",      216,  68, skipBlit ? 255 : 0,   skipBlit ? 255 : 0,   255},
      {"sprite BR",      248,  68, 255,                  255,                  skipBlit ? 255 : 0},
      {"alpha blit TL",  316, 136, 255, skipBlit ? 255 : 127, skipBlit ? 255 : 127},
  };
  int fails = 0;
  for (const auto& p : probes) {
    Px px = at(p.x, p.y);
    bool ok = abs((int)px.r - p.r) <= 10 && abs((int)px.g - p.g) <= 10 &&
              abs((int)px.b - p.b) <= 10;
    printf("%-16s (%3d,%3d) got=(%3d,%3d,%3d) want=(%3d,%3d,%3d) %s\n", p.name,
           p.x, p.y, px.r, px.g, px.b, p.r, p.g, p.b, ok ? "OK" : "MISMATCH");
    if (!ok) fails++;
  }

  FILE* f = fopen(skipBlit ? "/tmp/canvas-bench-noblit.ppm"
                           : "/tmp/canvas-bench.ppm", "wb");
  if (f) {
    fprintf(f, "P6\n%d %d\n255\n", W, H);
    for (int y = H - 1; y >= 0; --y)
      for (int x = 0; x < W; ++x) { Px p = buf[y * W + x]; fwrite(&p, 1, 3, f); }
    fclose(f);
  }

  // ---- 4. Throughput at the mac's MEASURED numbers -------------------------
  auto timeFrames = [&](int rects, int frames) {
    renderFrame(rects, !skipBlit);  // warm up: first frame pays pipeline setup
    glFinish();
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < frames; ++i) renderFrame(rects, !skipBlit);
    glFinish();
    auto t1 = std::chrono::steady_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count() / frames;
  };

  double steadyMs = timeFrames(steadyRects, timedFrames);
  double burstMs = timeFrames(burstRects, 5);
  printf("CANVAS_BENCH steady_rects=%d ms_per_frame=%.2f fps=%.1f\n",
         steadyRects, steadyMs, 1000.0 / steadyMs);
  printf("CANVAS_BENCH burst_rects=%d ms_per_frame=%.2f\n", burstRects, burstMs);
  printf("CANVAS_BENCH renderer=%s\n", (const char*)glGetString(GL_RENDERER));

  ImpellerTextureRelease(sprite);
  ImpellerSurfaceRelease(atlasSurface);
  ImpellerSurfaceRelease(surface);
  ImpellerContextRelease(ictx);

  if (fails) { printf("CANVAS_BENCH_FAIL (%d)\n", fails); return 1; }
  printf("CANVAS_BENCH_PASS%s\n", skipBlit ? " (negative control)" : "");
  return 0;
}
