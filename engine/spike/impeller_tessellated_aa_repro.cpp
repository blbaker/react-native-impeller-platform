// Minimal, self-contained Impeller repro: builder-composed (tessellated) paths
// render with NO edge anti-aliasing, while the AddOval analytic fast path AAs
// the identical circle -- same ImpellerPaint, same DisplayList, same Surface.
//
// No React-Native, no SVG parser, no app code. Only the Impeller C API + GLES.
// Build (from engine/):
//   SDK=third_party/impeller-sdk
//   g++ -std=c++17 spike/impeller_tessellated_aa_repro.cpp \
//     -I "$SDK/include" -L "$SDK/lib" -limpeller -lEGL -lGLESv2 \
//     -Wl,-rpath,"$PWD/$SDK/lib" -o /tmp/aa-repro && /tmp/aa-repro
//
// Emits /tmp/impeller_aa_repro.ppm : left disc = AddOval (AA'd rim),
// right disc = four kKappa cubics (hard binary rim). Same radius, same paint.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <cstdio>
#include <cstdlib>
#include <set>
#include <string>
#include <vector>

#include "impeller.h"

namespace {
constexpr int W = 400, H = 300;
constexpr float kKappa = 0.5522847498f;  // 4*(sqrt(2)-1)/3
struct Px { unsigned char r, g, b, a; };

#define CHECK(c, m) do { if (!(c)) { fprintf(stderr, "REPRO_FAIL: %s\n", m); exit(1); } } while (0)

void* ProcAddr(const char* n, void*) { return (void*)eglGetProcAddress(n); }

void InitEgl() {
  auto getDpy = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
  CHECK(getDpy, "eglGetPlatformDisplayEXT");
  EGLDisplay dpy = getDpy(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, nullptr);
  CHECK(dpy != EGL_NO_DISPLAY, "eglGetPlatformDisplay");
  EGLint mj = 0, mn = 0;
  CHECK(eglInitialize(dpy, &mj, &mn), "eglInitialize");
  const EGLint cfgA[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE,
                         EGL_OPENGL_ES3_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                         EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg; EGLint n = 0;
  CHECK(eglChooseConfig(dpy, cfgA, &cfg, 1, &n) && n == 1, "eglChooseConfig");
  CHECK(eglBindAPI(EGL_OPENGL_ES_API), "eglBindAPI");
  const EGLint ctxA[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
  EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxA);
  CHECK(ctx != EGL_NO_CONTEXT, "eglCreateContext");
  CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx), "eglMakeCurrent");
}

// A circle of radius r at (cx,cy) as four cubic Bezier arcs -- the standard
// curve every SVG/vector path uses. This is the tessellated route.
ImpellerPath CubicCircle(float cx, float cy, float r) {
  ImpellerPathBuilder pb = ImpellerPathBuilderNew();
  const float o = r * kKappa;
  ImpellerPoint start = {cx - r, cy};
  ImpellerPathBuilderMoveTo(pb, &start);
  const ImpellerPoint seg[4][3] = {
      {{cx - r, cy - o}, {cx - o, cy - r}, {cx, cy - r}},
      {{cx + o, cy - r}, {cx + r, cy - o}, {cx + r, cy}},
      {{cx + r, cy + o}, {cx + o, cy + r}, {cx, cy + r}},
      {{cx - o, cy + r}, {cx - r, cy + o}, {cx - r, cy}}};
  for (auto& s : seg) {
    ImpellerPoint c1 = s[0], c2 = s[1], e = s[2];
    ImpellerPathBuilderCubicCurveTo(pb, &c1, &c2, &e);
  }
  ImpellerPathBuilderClose(pb);
  ImpellerPath p = ImpellerPathBuilderTakePathNew(pb, kImpellerFillTypeNonZero);
  ImpellerPathBuilderRelease(pb);
  return p;
}

// The same circle via Impeller's analytic AddOval -- the fast path.
ImpellerPath OvalCircle(float cx, float cy, float r) {
  ImpellerPathBuilder pb = ImpellerPathBuilderNew();
  ImpellerRect box = {cx - r, cy - r, r * 2, r * 2};
  ImpellerPathBuilderAddOval(pb, &box);
  ImpellerPath p = ImpellerPathBuilderTakePathNew(pb, kImpellerFillTypeNonZero);
  ImpellerPathBuilderRelease(pb);
  return p;
}

void Histogram(const char* tag, const std::vector<Px>& buf, int x0, int y0, int span) {
  std::vector<int> ink; std::set<int> vals; int pure = 0, partial = 0;
  for (int dy = 0; dy < span; ++dy)
    for (int dx = 0; dx < span; ++dx) {
      int x = x0 + dx, y = y0 + dy;
      if (x >= W || y >= H) continue;
      const Px& p = buf[(H - 1 - y) * W + x];  // glReadPixels is bottom-left
      if (p.r == 255 && p.g == 255 && p.b == 255) continue;
      ink.push_back(p.r); vals.insert(p.r);
      if (p.r <= 8) pure++; else if (p.r < 247) partial++;
    }
  printf("  %-10s %5zu px | %5d pure / %5d partial = %5.1f%% partial | %zu distinct\n",
         tag, ink.size(), pure, partial,
         ink.empty() ? 0.0 : 100.0 * partial / ink.size(), vals.size());
}

void WritePpm(const char* path, const std::vector<Px>& buf) {
  FILE* f = fopen(path, "wb");
  CHECK(f, "fopen ppm");
  fprintf(f, "P6\n%d %d\n255\n", W, H);
  for (int y = 0; y < H; ++y)          // top-left origin for viewers
    for (int x = 0; x < W; ++x) {
      const Px& p = buf[(H - 1 - y) * W + x];
      fputc(p.r, f); fputc(p.g, f); fputc(p.b, f);
    }
  fclose(f);
}
}  // namespace

int main() {
  InitEgl();
  printf("GL_RENDERER=%s\n", (const char*)glGetString(GL_RENDERER));
  const char* ext = (const char*)glGetString(GL_EXTENSIONS);
  printf("GL_EXT_multisampled_render_to_texture=%s\n",
         (ext && std::string(ext).find("multisampled_render_to_texture") != std::string::npos)
             ? "present" : "ABSENT");

  ImpellerContext ictx = ImpellerContextCreateOpenGLESNew(IMPELLER_VERSION, &ProcAddr, nullptr);
  CHECK(ictx, "ImpellerContextCreateOpenGLESNew");

  // ONE display list, ONE paint, ONE surface. Left circle via AddOval, right
  // via cubics. Identical radius (60), identical paint. Nothing differs but the
  // builder primitive that composed the path.
  ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
  ImpellerPaint white = ImpellerPaintNew();
  ImpellerColor wc = {1, 1, 1, 1, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(white, &wc);
  ImpellerRect full = {0, 0, W, H};
  ImpellerDisplayListBuilderDrawRect(b, &full, white);

  ImpellerPaint black = ImpellerPaintNew();
  ImpellerColor bc = {0, 0, 0, 1, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(black, &bc);
  ImpellerPath oval = OvalCircle(100, 150, 60);
  ImpellerPath cub = CubicCircle(300, 150, 60);
  ImpellerDisplayListBuilderDrawPath(b, oval, black);
  ImpellerDisplayListBuilderDrawPath(b, cub, black);
  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);

  ImpellerISize size = {W, H};
  GLuint tex = 0, fbo = 0;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
  CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "FBO");
  ImpellerSurface s = ImpellerSurfaceCreateWrappedFBONew(ictx, fbo, kImpellerPixelFormatRGBA8888, &size);
  CHECK(s, "WrappedFBO");
  CHECK(ImpellerSurfaceDrawDisplayList(s, dl), "DrawDisplayList");
  glFinish();
  std::vector<Px> buf(W * H);
  glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, buf.data());
  CHECK(glGetError() == GL_NO_ERROR, "glReadPixels");

  printf("\nSame paint, same surface, same radius=60 circle:\n");
  Histogram("AddOval", buf, 30, 80, 140);
  Histogram("cubics", buf, 230, 80, 140);
  WritePpm("/tmp/impeller_aa_repro.ppm", buf);
  printf("\nwrote /tmp/impeller_aa_repro.ppm\nREPRO_DONE\n");

  ImpellerPathRelease(oval); ImpellerPathRelease(cub);
  ImpellerPaintRelease(white); ImpellerPaintRelease(black);
  ImpellerDisplayListRelease(dl); ImpellerSurfaceRelease(s);
  ImpellerContextRelease(ictx);
  return 0;
}
