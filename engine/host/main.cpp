// rn-impeller — P1 engine host.
//
// This is the PACKAGING payload, not the renderer. P2 replaces the body with a real
// bridgeless ReactInstance + Fabric mount; the CLI contract below is what P1 freezes:
//
//   rn-impeller --bundle <ABSOLUTE PATH> --app-name <NAME> [--headless] [--screenshot F]
//
// Deliberate design rules carried from the plan (D5) and from skia-platform's scars:
//   * --bundle is REQUIRED and must be absolute. There is NO CWD probe and NO
//     fallback bundle location, so a wrong path fails loudly instead of silently
//     rendering yesterday's bundle from some other directory.
//   * --app-name is REQUIRED and is echoed back: the name the host registers is the
//     name it runs. skia-platform shipped nine phases with a hardcoded "playground".
//   * The frame is a FUNCTION OF THE BUNDLE. If the bundle does not contain the
//     packaging shim marker, the status swatch is painted RED instead of GREEN.
//     That makes the consumer pixel gate prove the whole chain end to end
//     (tarball -> metro shim -> bundle -> engine -> pixels) rather than proving
//     only that a process exited zero.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "impeller.h"

namespace {

constexpr int kW = 400;
constexpr int kH = 300;
// Must match RN_IMPELLER_SHIM_MARKER in package/src/metro-shims/shims/Platform.impeller.js
constexpr const char* kShimMarker = "__RN_IMPELLER_SHIM_V1__";

void* ProcAddr(const char* name, void*) { return (void*)eglGetProcAddress(name); }

struct Px { unsigned char r, g, b, a; };

bool IsAbsolute(const std::string& p) {
#ifdef _WIN32
  return p.size() > 2 && p[1] == ':';
#else
  return !p.empty() && p[0] == '/';
#endif
}

bool ReadFile(const std::string& path, std::string* out) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) return false;
  char buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) out->append(buf, n);
  fclose(f);
  return true;
}

void Usage() {
  fprintf(stderr,
          "usage: rn-impeller --bundle <absolute path> --app-name <name>\n"
          "                   [--headless] [--screenshot <file.ppm>]\n");
}

}  // namespace

#define CHECK(cond, msg)                                  \
  do {                                                    \
    if (!(cond)) {                                        \
      fprintf(stderr, "rn-impeller: FATAL: %s\n", (msg)); \
      return 1;                                           \
    }                                                     \
  } while (0)

int main(int argc, char** argv) {
  std::string bundle_path, app_name, screenshot;
  bool headless = false;

  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&](const char* what) -> std::string {
      if (i + 1 >= argc) {
        fprintf(stderr, "rn-impeller: %s requires a value\n", what);
        exit(2);
      }
      return argv[++i];
    };
    if (a == "--bundle") bundle_path = next("--bundle");
    else if (a == "--app-name") app_name = next("--app-name");
    else if (a == "--screenshot") screenshot = next("--screenshot");
    else if (a == "--headless") headless = true;
    else if (a == "--help" || a == "-h") { Usage(); return 0; }
    // Unknown flags are ignored on purpose: the CLI forwards user args through.
  }

  if (bundle_path.empty() || app_name.empty()) {
    Usage();
    return 2;
  }
  // No CWD fallback. An engine that guesses the bundle location is an engine that
  // renders a stale bundle and wastes an afternoon.
  CHECK(IsAbsolute(bundle_path), "--bundle must be an ABSOLUTE path (no CWD fallback exists)");

  std::string bundle;
  if (!ReadFile(bundle_path, &bundle)) {
    fprintf(stderr, "rn-impeller: FATAL: cannot read bundle at %s\n", bundle_path.c_str());
    return 1;
  }

  const bool shim_ok = bundle.find(kShimMarker) != std::string::npos;
  printf("rn-impeller: app=%s\n", app_name.c_str());
  printf("rn-impeller: bundle=%s (%zu bytes)\n", bundle_path.c_str(), bundle.size());
  printf("rn-impeller: shim_marker=%s\n", shim_ok ? "PRESENT" : "MISSING");
  printf("rn-impeller: headless=%s\n", headless ? "yes" : "no");

  if (!headless) {
    // P2 brings the windowed WSI path. Until then be explicit rather than pretending.
    fprintf(stderr,
            "rn-impeller: windowed mode is not implemented yet (P2). "
            "Re-run with --headless.\n");
    return 3;
  }

  // ---- surfaceless EGL (works in CI with no display server) ----
  auto getPlatformDisplay =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
  CHECK(getPlatformDisplay != nullptr, "eglGetPlatformDisplayEXT unavailable");
  EGLDisplay dpy = getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, nullptr);
  CHECK(dpy != EGL_NO_DISPLAY, "surfaceless eglGetPlatformDisplay");
  EGLint egl_major = 0, egl_minor = 0;
  CHECK(eglInitialize(dpy, &egl_major, &egl_minor), "eglInitialize");

  const EGLint cfg_attrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                              EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                              EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                              EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg;
  EGLint n = 0;
  CHECK(eglChooseConfig(dpy, cfg_attrs, &cfg, 1, &n) && n == 1, "eglChooseConfig");
  CHECK(eglBindAPI(EGL_OPENGL_ES_API), "eglBindAPI");
  const EGLint ctx_attrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
  EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
  CHECK(ctx != EGL_NO_CONTEXT, "eglCreateContext");
  CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx), "eglMakeCurrent surfaceless");
  printf("rn-impeller: GL_RENDERER=%s\n", (const char*)glGetString(GL_RENDERER));

  GLuint tex = 0, fbo = 0;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, kW, kH, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
  CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "FBO incomplete");

  ImpellerContext ictx = ImpellerContextCreateOpenGLESNew(IMPELLER_VERSION, &ProcAddr, nullptr);
  CHECK(ictx != nullptr, "ImpellerContextCreateOpenGLESNew returned null");
  ImpellerISize size = {kW, kH};
  ImpellerSurface surface =
      ImpellerSurfaceCreateWrappedFBONew(ictx, fbo, kImpellerPixelFormatRGBA8888, &size);
  CHECK(surface != nullptr, "ImpellerSurfaceCreateWrappedFBONew returned null");

  ImpellerDisplayListBuilder builder = ImpellerDisplayListBuilderNew(nullptr);
  ImpellerPaint paint = ImpellerPaintNew();

  ImpellerColor white = {1.0f, 1.0f, 1.0f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &white);
  ImpellerRect full = {0, 0, (float)kW, (float)kH};
  ImpellerDisplayListBuilderDrawRect(builder, &full, paint);

  // Status swatch: GREEN only if the packaging shim actually reached the bundle.
  ImpellerColor status = shim_ok ? ImpellerColor{0.0f, 1.0f, 0.0f, 1.0f, kImpellerColorSpaceSRGB}
                                 : ImpellerColor{1.0f, 0.0f, 0.0f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &status);
  ImpellerRect swatch = {20, 20, 100, 100};  // {x, y, w, h} — NOT LTRB
  ImpellerDisplayListBuilderDrawRect(builder, &swatch, paint);

  // Rounded rect + oval: shape fidelity probes (the subtle-mutation gate targets).
  ImpellerColor blue = {0.0f, 0.0f, 1.0f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &blue);
  ImpellerRect r2 = {200, 20, 150, 100};
  ImpellerRoundingRadii radii = {};
  radii.top_left = {20, 20};
  radii.bottom_left = {20, 20};  // field order is TL, BL, TR, BR
  radii.top_right = {20, 20};
  radii.bottom_right = {20, 20};
  ImpellerDisplayListBuilderDrawRoundedRect(builder, &r2, &radii, paint);

  // Bundle-size bar: width scales with the bundle, so an empty/truncated bundle is
  // visible in pixels, not just in a log line.
  ImpellerColor grey = {0.35f, 0.35f, 0.35f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &grey);
  float bar_w = (float)(bundle.size() / 4096);
  if (bar_w > (float)(kW - 40)) bar_w = (float)(kW - 40);
  if (bar_w < 1.0f) bar_w = 1.0f;
  ImpellerRect bar = {20, 250, bar_w, 20};
  ImpellerDisplayListBuilderDrawRect(builder, &bar, paint);

  // Anti-aliased CIRCLE. Two jobs: shape-fidelity probe target, and it is what makes
  // the distinct-colour floor meaningful — a frame of axis-aligned rects has only a
  // handful of colours, so a floor measured over such a frame proves nothing.
  //
  // It must be a circle, NOT an ellipse. Verified on this SDK pin + llvmpipe: an oval
  // with width != height draws with NO anti-aliasing at all (hard edges, 4 distinct
  // colours in the frame), while width == height produces ~40 fringe colours. Making
  // this an ellipse silently removes every AA pixel and guts the colour floor.
  ImpellerColor purple = {0.5f, 0.0f, 0.6f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &purple);
  ImpellerRect circle = {150, 140, 90, 90};
  ImpellerDisplayListBuilderDrawOval(builder, &circle, paint);


  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(builder);
  CHECK(dl != nullptr, "CreateDisplayListNew");
  CHECK(ImpellerSurfaceDrawDisplayList(surface, dl), "SurfaceDrawDisplayList returned false");
  glFinish();

  std::vector<Px> buf(kW * kH);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glReadPixels(0, 0, kW, kH, GL_RGBA, GL_UNSIGNED_BYTE, buf.data());
  CHECK(glGetError() == GL_NO_ERROR, "glReadPixels");
  // glReadPixels origin is bottom-left; Impeller draws top-left.
  auto at = [&](int x, int y_topleft) -> Px { return buf[(kH - 1 - y_topleft) * kW + x]; };

  Px s = at(70, 70);
  printf("rn-impeller: status_swatch_rgb=%d,%d,%d\n", s.r, s.g, s.b);

  // Shape-fidelity probe: inside the rounded rect's bounding box but OUTSIDE its
  // rounded corner, so background must show through. This is the probe that catches
  // a subtle wrong-shape regression; a swatch-only gate cannot.
  Px c = at(202, 22);
  printf("rn-impeller: rrect_corner_rgb=%d,%d,%d\n", c.r, c.g, c.b);

  int distinct = 0;
  {
    std::vector<unsigned> seen;
    for (auto& p : buf) {
      unsigned k = (p.r << 16) | (p.g << 8) | p.b;
      bool found = false;
      for (auto v : seen)
        if (v == k) { found = true; break; }
      if (!found && seen.size() < 4096) seen.push_back(k);
    }
    distinct = (int)seen.size();
  }
  printf("rn-impeller: distinct_colors=%d\n", distinct);

  if (!screenshot.empty()) {
    FILE* f = fopen(screenshot.c_str(), "wb");
    if (f) {
      fprintf(f, "P6\n%d %d\n255\n", kW, kH);
      for (int y = kH - 1; y >= 0; --y)
        for (int x = 0; x < kW; ++x) {
          Px p = buf[y * kW + x];
          fwrite(&p, 1, 3, f);
        }
      fclose(f);
      printf("rn-impeller: screenshot=%s\n", screenshot.c_str());
    } else {
      fprintf(stderr, "rn-impeller: WARN: cannot write screenshot %s\n", screenshot.c_str());
    }
  }

  ImpellerDisplayListRelease(dl);
  ImpellerPaintRelease(paint);
  ImpellerDisplayListBuilderRelease(builder);
  ImpellerSurfaceRelease(surface);
  ImpellerContextRelease(ictx);

  if (!shim_ok) {
    printf("RN_IMPELLER_FAIL (packaging shim marker absent from bundle)\n");
    return 4;
  }
  printf("RN_IMPELLER_RENDER_OK app=%s\n", app_name.c_str());
  return 0;
}
