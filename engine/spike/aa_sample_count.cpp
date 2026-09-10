// ENG-05c: is Impeller's missing edge anti-aliasing a PAINT property, a
// SURFACE sample-count property, or something else entirely?
//
// The ticket blames the stroke draw call at SceneGraph.cpp:929 and asks for
// "path fill and stroke paints get anti-aliasing on". Two things make that
// suspect:
//
//   1. probe-eng05-aa.sh measures 0.0% partial coverage on BOTH a filled disc
//      and a stroked ring, so whatever is off is not stroke-specific.
//   2. The Impeller C API has exactly 11 ImpellerPaintSet* entry points
//      (color, blend, draw style, cap, join, width, miter, colour filter,
//      colour source, image filter, mask filter). None is anti-aliasing.
//      There is no paint bit to turn on.
//
// So this walks the SAME two circles down progressively more production-like
// routes and reports edge coverage for each. A circle is the discriminating
// shape: its edge samples every angle, so AA (if on) MUST produce intermediate
// luminance -- unlike an axis-aligned rect, whose edges land on pixel
// boundaries and legitimately show none.
//
//   A  DrawOval, single-sample FBO      (what HeadlessSurface.cpp builds)
//   B  DrawOval, 4x MSAA FBO            (is AA a sample-count property?)
//   C  AddOval  -> DrawPath             (the call SceneGraph.cpp makes)
//   D  C inside the SVG root's clip     (does the viewBox clip kill it?)
//   E  ellipseToPathData -> parser      (the real <Circle> chain)
//   F  same cubics, no parser           (is our parser at fault?)
//   G  triangle, LineTo only            (is it curves specifically?)
//   H  AddOval vs cubics, ONE list      (the control)
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <cstdio>
#include <cstdlib>
#include <set>
#include <string>
#include <vector>

#include "impeller.h"
#include "svg/SvgPath.h"

namespace {

constexpr int W = 400, H = 300;
// Standard circle-to-Bezier constant 4*(sqrt(2)-1)/3 -- the same one
// SceneGraph.cpp:177 uses, so this is production geometry, not a lookalike.
constexpr float kKappa = 0.5522847498f;

void* ProcAddr(const char* name, void*) { return (void*)eglGetProcAddress(name); }

#define CHECK(cond, msg)                           \
  do {                                             \
    if (!(cond)) {                                 \
      fprintf(stderr, "AA_SPIKE_FAIL: %s\n", msg); \
      exit(1);                                     \
    }                                              \
  } while (0)

struct Px { unsigned char r, g, b, a; };

// The two circles every arm draws, in SVG user space.
struct Circle { float cx, cy, r; };
constexpr Circle kDisc{100, 100, 60};   // filled  -> rim is the FILL's AA
constexpr Circle kRing{280, 100, 60};   // stroked -> rims are the STROKE's AA
constexpr float kStrokeWidth = 6.0f;

ImpellerRect BoxOf(const Circle& c) {
  return {c.cx - c.r, c.cy - c.r, c.r * 2, c.r * 2};
}

// ---------------------------------------------------------------------------
// Measurement. Same ink test and same pure/partial thresholds as
// tools/eng05-aa-analyse.py, so this spike and the JS probe cannot disagree by
// definition drift.
// ---------------------------------------------------------------------------
void Histogram(const char* arm, const std::vector<Px>& buf, int x0, int y0,
               int span, const char* region) {
  std::vector<int> ink;
  for (int dy = 0; dy < span; ++dy) {
    for (int dx = 0; dx < span; ++dx) {
      const int x = x0 + dx, y = y0 + dy;
      if (x >= W || y >= H) continue;
      // glReadPixels is bottom-left origin; Impeller draws top-left.
      const Px& p = buf[(H - 1 - y) * W + x];
      if (!(p.r == 255 && p.g == 255 && p.b == 255)) ink.push_back(p.r);
    }
  }
  if (ink.empty()) {
    printf("  %-6s %-12s PAINTED NOTHING\n", arm, region);
    return;
  }
  int pure = 0, partial = 0;
  std::set<int> vals;
  for (int v : ink) {
    if (v <= 8) pure++;
    else if (v < 247) partial++;
    vals.insert(v);
  }
  printf("  %-6s %-12s %5zu px | %5d pure / %5d partial = %5.1f%% partial |"
         " %zu distinct\n",
         arm, region, ink.size(), pure, partial,
         100.0 * partial / (double)ink.size(), vals.size());
}

// Both circles sit in these boxes; a generous margin around each.
void Report(const char* arm, const std::vector<Px>& buf) {
  Histogram(arm, buf, 30, 30, 140, "FILL_disc");
  Histogram(arm, buf, 210, 30, 140, "STROKE_ring");
}

// ---------------------------------------------------------------------------
// Scene construction. Every arm is the same two circles down a different route,
// so the route is a parameter rather than six near-identical builders.
// ---------------------------------------------------------------------------
enum class Route {
  kDrawOval,  // ImpellerDisplayListBuilderDrawOval -- no path at all
  kAddOval,   // ImpellerPathBuilderAddOval -> DrawPath
  kCubics,    // MoveTo + 4 CubicCurveTo + Close -> DrawPath
  kParsed,    // ellipseToPathData string -> ParseSvgPathToBuilder -> DrawPath
};

// Verbatim SceneGraph.cpp:186 ellipseToPathData spelling.
std::string EllipseD(const Circle& c) {
  const float cx = c.cx, cy = c.cy, rx = c.r, ry = c.r;
  const float ox = rx * kKappa, oy = ry * kKappa;
  char buf[512];
  std::snprintf(buf, sizeof(buf),
                "M%g %g C%g %g %g %g %g %g C%g %g %g %g %g %g "
                "C%g %g %g %g %g %g C%g %g %g %g %g %g Z",
                cx - rx, cy,
                cx - rx, cy - oy, cx - ox, cy - ry, cx, cy - ry,
                cx + ox, cy - ry, cx + rx, cy - oy, cx + rx, cy,
                cx + rx, cy + oy, cx + ox, cy + ry, cx, cy + ry,
                cx - ox, cy + ry, cx - rx, cy + oy, cx - rx, cy);
  return buf;
}

void AddCubicEllipse(ImpellerPathBuilder pb, const Circle& c) {
  const float cx = c.cx, cy = c.cy, rx = c.r, ry = c.r;
  const float ox = rx * kKappa, oy = ry * kKappa;
  ImpellerPoint start = {cx - rx, cy};
  ImpellerPathBuilderMoveTo(pb, &start);
  const ImpellerPoint segs[4][3] = {
      {{cx - rx, cy - oy}, {cx - ox, cy - ry}, {cx, cy - ry}},
      {{cx + ox, cy - ry}, {cx + rx, cy - oy}, {cx + rx, cy}},
      {{cx + rx, cy + oy}, {cx + ox, cy + ry}, {cx, cy + ry}},
      {{cx - ox, cy + ry}, {cx - rx, cy + oy}, {cx - rx, cy}},
  };
  for (const auto& s : segs) {
    ImpellerPoint c1 = s[0], c2 = s[1], e = s[2];
    ImpellerPathBuilderCubicCurveTo(pb, &c1, &c2, &e);
  }
  ImpellerPathBuilderClose(pb);
}

// Builds the circle as a path by the given route. Caller releases.
ImpellerPath PathFor(Route route, const Circle& c) {
  ImpellerPathBuilder pb = ImpellerPathBuilderNew();
  CHECK(pb != nullptr, "PathBuilderNew");
  switch (route) {
    case Route::kAddOval: {
      ImpellerRect box = BoxOf(c);
      ImpellerPathBuilderAddOval(pb, &box);
      break;
    }
    case Route::kCubics:
      AddCubicEllipse(pb, c);
      break;
    case Route::kParsed:
      CHECK(rni::ParseSvgPathToBuilder(EllipseD(c), pb), "ParseSvgPathToBuilder");
      break;
    case Route::kDrawOval:
      CHECK(false, "kDrawOval has no path");
      break;
  }
  ImpellerPath p = ImpellerPathBuilderTakePathNew(pb, kImpellerFillTypeNonZero);
  CHECK(p != nullptr, "TakePathNew");
  ImpellerPathBuilderRelease(pb);
  return p;
}

// Black, opaque; stroked variants carry the SVG stroke width.
ImpellerPaint BlackPaint(bool stroked) {
  ImpellerPaint p = ImpellerPaintNew();
  ImpellerColor black = {0, 0, 0, 1, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(p, &black);
  if (stroked) {
    ImpellerPaintSetDrawStyle(p, kImpellerDrawStyleStroke);
    ImpellerPaintSetStrokeWidth(p, kStrokeWidth);
  }
  return p;
}

void DrawWhiteBackground(ImpellerDisplayListBuilder b) {
  ImpellerPaint bg = ImpellerPaintNew();
  ImpellerColor white = {1, 1, 1, 1, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(bg, &white);
  ImpellerRect full = {0, 0, (float)W, (float)H};
  ImpellerDisplayListBuilderDrawRect(b, &full, bg);
  ImpellerPaintRelease(bg);
}

void DrawCircle(ImpellerDisplayListBuilder b, Route route, const Circle& c,
                bool stroked) {
  ImpellerPaint paint = BlackPaint(stroked);
  if (route == Route::kDrawOval) {
    ImpellerRect box = BoxOf(c);
    ImpellerDisplayListBuilderDrawOval(b, &box, paint);
  } else {
    ImpellerPath p = PathFor(route, c);
    ImpellerDisplayListBuilderDrawPath(b, p, paint);
    ImpellerPathRelease(p);
  }
  ImpellerPaintRelease(paint);
}

// Arms A-F: filled disc + stroked ring, one route, optionally wrapped in the
// SAME Save/ClipRect/Transform/Translate the SVG root emits
// (SceneGraph.cpp:886-895 plus the per-node translate at 997).
ImpellerDisplayList BuildCircles(Route route, bool clipped = false) {
  ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
  CHECK(b != nullptr, "DisplayListBuilderNew");
  DrawWhiteBackground(b);

  if (clipped) {
    // viewBox "0 0 400 300" into a 400x300 frame => identity scale, no offset.
    ImpellerDisplayListBuilderSave(b);
    ImpellerRect vbClip = {0, 0, (float)W, (float)H};
    ImpellerDisplayListBuilderClipRect(b, &vbClip, kImpellerClipOperationIntersect);
    ImpellerMatrix vbm = {{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}};
    ImpellerDisplayListBuilderTransform(b, &vbm);
    ImpellerDisplayListBuilderSave(b);
    ImpellerDisplayListBuilderTranslate(b, 0, 0);
  }

  DrawCircle(b, route, kDisc, /*stroked=*/false);
  DrawCircle(b, route, kRing, /*stroked=*/true);

  if (clipped) {
    ImpellerDisplayListBuilderRestore(b);  // node translate
    ImpellerDisplayListBuilderRestore(b);  // viewBox clip
  }

  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);
  CHECK(dl != nullptr, "CreateDisplayListNew");
  ImpellerDisplayListBuilderRelease(b);
  return dl;
}

// Arm G: a diagonal triangle, MoveTo/LineTo only, NO curves. Its sloped edges
// cannot land on pixel boundaries, so AA (if on for builder-built paths) must
// show partial coverage. Separates "cubics lose AA" from "any hand-built path
// loses AA, and only Impeller's AddOval fast path keeps it".
ImpellerDisplayList BuildTriangle() {
  ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
  CHECK(b != nullptr, "DisplayListBuilderNew (tri)");
  DrawWhiteBackground(b);

  ImpellerPathBuilder pb = ImpellerPathBuilderNew();
  ImpellerPoint apex = {100, 40}, right = {160, 160}, left = {40, 160};
  ImpellerPathBuilderMoveTo(pb, &apex);
  ImpellerPathBuilderLineTo(pb, &right);
  ImpellerPathBuilderLineTo(pb, &left);
  ImpellerPathBuilderClose(pb);
  ImpellerPath p = ImpellerPathBuilderTakePathNew(pb, kImpellerFillTypeNonZero);
  CHECK(p != nullptr, "TakePathNew tri");
  ImpellerPaint fill = BlackPaint(/*stroked=*/false);
  ImpellerDisplayListBuilderDrawPath(b, p, fill);

  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);
  CHECK(dl != nullptr, "CreateDisplayListNew (tri)");
  ImpellerPaintRelease(fill);
  ImpellerPathRelease(p);
  ImpellerPathBuilderRelease(pb);
  ImpellerDisplayListBuilderRelease(b);
  return dl;
}

// Arm H: THE CONTROL. Both discs in ONE display list, ONE paint, ONE surface --
// left via AddOval, right via cubics. Arms C and F measure these separately, so
// a sceptic can still blame per-list or per-surface state. Here the only
// difference left is which builder primitive composed the path.
ImpellerDisplayList BuildSideBySide() {
  ImpellerDisplayListBuilder b = ImpellerDisplayListBuilderNew(nullptr);
  CHECK(b != nullptr, "DisplayListBuilderNew (side)");
  DrawWhiteBackground(b);

  ImpellerPaint fill = BlackPaint(/*stroked=*/false);
  for (auto [route, c] : {std::pair{Route::kAddOval, kDisc},
                          std::pair{Route::kCubics, kRing}}) {
    ImpellerPath p = PathFor(route, c);
    ImpellerDisplayListBuilderDrawPath(b, p, fill);
    ImpellerPathRelease(p);
  }

  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(b);
  CHECK(dl != nullptr, "CreateDisplayListNew (side)");
  ImpellerPaintRelease(fill);
  ImpellerDisplayListBuilderRelease(b);
  return dl;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

// Exactly the FBO HeadlessSurface.cpp:116-134 builds: a plain single-sample
// GL_TEXTURE_2D colour attachment.
void RenderSingleSample(ImpellerContext ictx, ImpellerDisplayList dl,
                        std::vector<Px>* out) {
  ImpellerISize size = {W, H};
  GLuint tex = 0, fbo = 0;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE,
               nullptr);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         tex, 0);
  CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
        "single-sample FBO incomplete");
  ImpellerSurface s = ImpellerSurfaceCreateWrappedFBONew(
      ictx, fbo, kImpellerPixelFormatRGBA8888, &size);
  CHECK(s != nullptr, "WrappedFBO returned null");
  CHECK(ImpellerSurfaceDrawDisplayList(s, dl), "DrawDisplayList false");
  glFinish();
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  out->resize(W * H);
  glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, out->data());
  CHECK(glGetError() == GL_NO_ERROR, "glReadPixels");
  ImpellerSurfaceRelease(s);
}

// One arm: build, render single-sample, measure, release.
void RunArm(const char* arm, const char* title, ImpellerContext ictx,
            ImpellerDisplayList dl, bool circles = true) {
  printf("\n== arm %s: %s ==\n", arm, title);
  std::vector<Px> buf;
  RenderSingleSample(ictx, dl, &buf);
  ImpellerDisplayListRelease(dl);
  if (circles) {
    Report(arm, buf);
  } else {
    Histogram(arm, buf, 30, 30, 140, "TRI_fill");
  }
}

EGLContext InitEgl() {
  auto getPlatformDisplay = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
      "eglGetPlatformDisplayEXT");
  CHECK(getPlatformDisplay != nullptr, "eglGetPlatformDisplayEXT unavailable");
  EGLDisplay dpy = getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                                      EGL_DEFAULT_DISPLAY, nullptr);
  CHECK(dpy != EGL_NO_DISPLAY, "surfaceless eglGetPlatformDisplay");
  EGLint major = 0, minor = 0;
  CHECK(eglInitialize(dpy, &major, &minor), "eglInitialize");

  const EGLint cfgAttrs[] = {EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
                             EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                             EGL_RED_SIZE,        8,
                             EGL_GREEN_SIZE,      8,
                             EGL_BLUE_SIZE,       8,
                             EGL_ALPHA_SIZE,      8,
                             EGL_NONE};
  EGLConfig cfg;
  EGLint n = 0;
  CHECK(eglChooseConfig(dpy, cfgAttrs, &cfg, 1, &n) && n == 1, "eglChooseConfig");
  CHECK(eglBindAPI(EGL_OPENGL_ES_API), "eglBindAPI");
  const EGLint ctxAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
  EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxAttrs);
  CHECK(ctx != EGL_NO_CONTEXT, "eglCreateContext");
  CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx),
        "eglMakeCurrent surfaceless");
  return ctx;
}

// Arm B is the only one that does not use RenderSingleSample: it hands Impeller
// a 4x multisampled renderbuffer and blit-resolves it.
void RunMsaaArm(ImpellerContext ictx, GLint maxSamples) {
  printf("\n== arm B: 4x multisampled renderbuffer FBO, blit-resolved ==\n");
  if (maxSamples < 4) {
    printf("  SKIPPED: driver reports GL_MAX_SAMPLES=%d\n", maxSamples);
    return;
  }
  ImpellerISize size = {W, H};
  GLuint rb = 0, msFbo = 0, resolveTex = 0, resolveFbo = 0;
  glGenRenderbuffers(1, &rb);
  glBindRenderbuffer(GL_RENDERBUFFER, rb);
  glRenderbufferStorageMultisample(GL_RENDERBUFFER, 4, GL_RGBA8, W, H);
  glGenFramebuffers(1, &msFbo);
  glBindFramebuffer(GL_FRAMEBUFFER, msFbo);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                            GL_RENDERBUFFER, rb);
  const GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
  if (st != GL_FRAMEBUFFER_COMPLETE) {
    printf("  MSAA FBO incomplete (status 0x%x) -- cannot run arm B\n", st);
    return;
  }
  // Impeller may reject a multisampled target; that refusal is itself a
  // finding, so report it rather than aborting the whole spike.
  ImpellerSurface s = ImpellerSurfaceCreateWrappedFBONew(
      ictx, msFbo, kImpellerPixelFormatRGBA8888, &size);
  if (s == nullptr) {
    printf("  ImpellerSurfaceCreateWrappedFBONew REFUSED the 4x MSAA FBO"
           " (returned null)\n");
    return;
  }
  ImpellerDisplayList dl = BuildCircles(Route::kDrawOval);
  const bool drew = ImpellerSurfaceDrawDisplayList(s, dl);
  printf("  DrawDisplayList on MSAA target -> %s\n", drew ? "true" : "FALSE");
  glFinish();

  glGenTextures(1, &resolveTex);
  glBindTexture(GL_TEXTURE_2D, resolveTex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE,
               nullptr);
  glGenFramebuffers(1, &resolveFbo);
  glBindFramebuffer(GL_FRAMEBUFFER, resolveFbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         resolveTex, 0);
  CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
        "resolve FBO incomplete");
  glBindFramebuffer(GL_READ_FRAMEBUFFER, msFbo);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, resolveFbo);
  glBlitFramebuffer(0, 0, W, H, 0, 0, W, H, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  CHECK(glGetError() == GL_NO_ERROR, "glBlitFramebuffer resolve");
  glBindFramebuffer(GL_FRAMEBUFFER, resolveFbo);
  std::vector<Px> buf(W * H);
  glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, buf.data());
  CHECK(glGetError() == GL_NO_ERROR, "arm B glReadPixels");
  if (drew) Report("B", buf);

  ImpellerDisplayListRelease(dl);
  ImpellerSurfaceRelease(s);
}

}  // namespace

int main() {
  InitEgl();
  GLint maxSamples = 0;
  glGetIntegerv(GL_MAX_SAMPLES, &maxSamples);
  printf("GL_RENDERER=%s\nGL_MAX_SAMPLES=%d\n",
         (const char*)glGetString(GL_RENDERER), maxSamples);

  ImpellerContext ictx =
      ImpellerContextCreateOpenGLESNew(IMPELLER_VERSION, &ProcAddr, nullptr);
  CHECK(ictx != nullptr, "ImpellerContextCreateOpenGLESNew returned null");

  RunArm("A", "single-sample FBO (what HeadlessSurface.cpp builds)", ictx,
         BuildCircles(Route::kDrawOval));
  RunMsaaArm(ictx, maxSamples);
  RunArm("C", "same circles as PATHS via DrawPath (the SceneGraph call)", ictx,
         BuildCircles(Route::kAddOval));
  RunArm("D", "DrawPath inside the SVG root's Save/ClipRect/Transform", ictx,
         BuildCircles(Route::kAddOval, /*clipped=*/true));
  RunArm("E",
         "<Circle> the production way -- ellipseToPathData string"
         " -> ParseSvgPathToBuilder -> DrawPath",
         ictx, BuildCircles(Route::kParsed));
  RunArm("F", "same four cubics, direct builder calls, NO parser", ictx,
         BuildCircles(Route::kCubics));
  RunArm("G", "diagonal triangle, LineTo only, no curves", ictx,
         BuildTriangle(), /*circles=*/false);

  printf("\n== arm H: CONTROL -- AddOval vs cubics, ONE list, ONE paint ==\n");
  {
    std::vector<Px> buf;
    ImpellerDisplayList dl = BuildSideBySide();
    RenderSingleSample(ictx, dl, &buf);
    ImpellerDisplayListRelease(dl);
    Histogram("H", buf, 30, 30, 140, "AddOval");
    Histogram("H", buf, 210, 30, 140, "cubics");
  }

  ImpellerContextRelease(ictx);
  printf("\nAA_SPIKE_DONE\n");
  return 0;
}
