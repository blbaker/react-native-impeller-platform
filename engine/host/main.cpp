// rn-impeller — the engine host.
//
// CLI contract, FROZEN BY P1 (package/src/cli/run.js and the resolver depend on
// every word of it):
//
//   rn-impeller --bundle <ABSOLUTE PATH> --app-name <NAME>
//               [--headless] [--screenshot F] [--probe-banner on|off]
//               [--width N] [--height N] [--log-mutations]
//
//   * --bundle is REQUIRED and ABSOLUTE. There is no CWD probe and no fallback
//     location, so a wrong path fails loudly instead of quietly rendering some
//     other directory's stale bundle.
//   * --app-name is REQUIRED and is the name actually registered AND run.
//
// WHAT --probe-banner IS, AND WHY IT DEFAULTS ON IN HEADLESS MODE
//
// The banner is the P1 packaging self-test frame: a status swatch that is GREEN
// only when the packaging shim marker is present in the loaded bundle (RED
// otherwise), a rounded rect whose corner must show background, an anti-aliased
// circle, and a bar scaled to the bundle size. It is drawn OVER an opaque
// backdrop, so with the banner on the frame proves the PACKAGING chain and says
// nothing about React.
//
// `--probe-banner off` paints the React scene graph alone — that is the frame
// the P2 gate reads. Two frames because they answer two different questions,
// and a single frame that tried to answer both would answer neither when it
// went wrong. The banner never draws in windowed mode; it is a test artifact,
// not UI.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#include "fabric/FabricHost.h"
#include "host/HeadlessSurface.h"
#include "impeller.h"
#include "runtime/FeatureFlags.h"
#include "runtime/ReactHost.h"
#include "scenegraph/SceneGraph.h"

namespace {

// Must match RN_IMPELLER_SHIM_MARKER in
// package/src/metro-shims/shims/Platform.impeller.js
constexpr const char* kShimMarker = "__RN_IMPELLER_SHIM_V1__";

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
          "                   [--headless] [--screenshot <file.ppm>]\n"
          "                   [--probe-banner on|off] [--width N] [--height N]\n"
          "                   [--log-mutations] [--color-scheme light|dark]\n"
          "                   [--initial-url URL]\n"
          "       rn-impeller --list-modules   (module seam manifest; no bundle)\n"
          "       rn-impeller --test-openurl   (URL predicate self-test)\n");
}

// Prints the TurboModule seam as a machine-readable manifest:
//
//   module=<Name> methods=<a,b,c>
//
// This exists so the P4 packaging gate can diff the NATIVE method map against
// the JS that actually ships in the tarball — the "method in shim" guard. A
// file-presence check passes happily while half a module's methods are
// unreachable from JS, which is how four of eleven methods once shipped
// uncallable with every gate green.
//
// ⛔ IT ENUMERATES FROM JAVASCRIPT, NOT FROM C++, AND THAT IS THE WHOLE POINT.
// Reading `methodMap_` in C++ would answer "what did we register", which is
// the question we already know the answer to. Reaching the module the way a
// bundle does answers "what can JS actually CALL". A module that registers
// perfectly and is unreachable through the binding (wrong install order,
// non-bridgeless path, name mismatch) is invisible to the first question and
// caught by the second.
//
// ⚠️ TWO GLOBALS THAT ARE EASY TO GET WRONG, BOTH READ FROM SOURCE RATHER
// THAN ASSUMED:
//
//  1. The access path is `nativeModuleProxy`, NOT `__turboModuleProxy`.
//     TurboModuleBinding::install() branches on `global.RN$Bridgeless` and
//     installs `__turboModuleProxy` ONLY on the legacy path; bridgeless
//     (which we are) defines a read-only `nativeModuleProxy` host object.
//  2. The global object is `globalThis`, not `global`. RN's `global` alias is
//     set up by InitializeCore, which a bare diagnostic script never loads —
//     so `global.x` throws ReferenceError and every module reads as
//     unreachable.
//
// Both mistakes produce the SAME output: "<UNREACHABLE FROM JS>" for every
// module, i.e. a gate failing for a reason with nothing to do with what it
// tests. Verified against a live run before trusting the manifest.
//
// It boots a real ReactHost, so it also proves every module CONSTRUCTS.
int ListModules() {
  rni::ReactHost host;
  auto registry = host.modules();

  // Build the name list as a JS array literal from the registry, so the
  // manifest cannot drift from what the engine vends.
  std::string names;
  for (const auto& n : registry->names()) {
    if (!names.empty()) names += ",";
    names += "'" + n + "'";
  }

  std::string script =
      "(function(){\n"
      "  var g = globalThis;\n"
      "  var names = [" + names + "];\n"
      "  for (var i = 0; i < names.length; i++) {\n"
      "    var n = names[i];\n"
      "    var m = null;\n"
      "    try { m = g.nativeModuleProxy[n]; } catch (e) {}\n"
      "    if (m == null) { console.log('module=' + n + ' methods=<UNREACHABLE FROM JS>'); continue; }\n"
      "    var keys = [];\n"
      "    for (var k in m) { keys.push(k); }\n"
      "    keys.sort();\n"
      "    console.log('module=' + n + ' methods=' + keys.join(','));\n"
      "  }\n"
      "  console.log('MODULE_MANIFEST_END');\n"
      "})();\n";

  host.runScript(std::move(script), "file://list-modules.js");
  if (!host.waitForJsIdle(10000)) {
    fprintf(stderr, "rn-impeller: --list-modules: JS never went idle\n");
    return 1;
  }
  return 0;
}

void DrawProbeBanner(ImpellerDisplayListBuilder builder, bool shimOk,
                     size_t bundleSize, int w, int h) {
  ImpellerPaint paint = ImpellerPaintNew();

  ImpellerColor white = {1.0f, 1.0f, 1.0f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &white);
  ImpellerRect full = {0, 0, (float)w, (float)h};
  ImpellerDisplayListBuilderDrawRect(builder, &full, paint);

  // GREEN only if the packaging shim actually reached the bundle.
  ImpellerColor status = shimOk
      ? ImpellerColor{0.0f, 1.0f, 0.0f, 1.0f, kImpellerColorSpaceSRGB}
      : ImpellerColor{1.0f, 0.0f, 0.0f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &status);
  ImpellerRect swatch = {20, 20, 100, 100};  // {x,y,w,h}, NOT LTRB
  ImpellerDisplayListBuilderDrawRect(builder, &swatch, paint);

  ImpellerColor blue = {0.0f, 0.0f, 1.0f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &blue);
  ImpellerRect r2 = {200, 20, 150, 100};
  ImpellerRoundingRadii radii = {};
  radii.top_left = {20, 20};
  radii.bottom_left = {20, 20};  // field order is TL, BL, TR, BR
  radii.top_right = {20, 20};
  radii.bottom_right = {20, 20};
  ImpellerDisplayListBuilderDrawRoundedRect(builder, &r2, &radii, paint);

  ImpellerColor grey = {0.35f, 0.35f, 0.35f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &grey);
  float barW = (float)(bundleSize / 4096);
  if (barW > (float)(w - 40)) barW = (float)(w - 40);
  if (barW < 1.0f) barW = 1.0f;
  ImpellerRect bar = {20, 250, barW, 20};
  ImpellerDisplayListBuilderDrawRect(builder, &bar, paint);

  // Must be a CIRCLE, not an ellipse: with width != height Impeller draws with
  // no anti-aliasing at all (4 distinct colours in the frame), which silently
  // guts the distinct-colour floor this gate depends on.
  ImpellerColor purple = {0.5f, 0.0f, 0.6f, 1.0f, kImpellerColorSpaceSRGB};
  ImpellerPaintSetColor(paint, &purple);
  ImpellerRect circle = {150, 140, 90, 90};
  ImpellerDisplayListBuilderDrawOval(builder, &circle, paint);

  ImpellerPaintRelease(paint);
}

int CountDistinctColors(const std::vector<rni::Px>& px) {
  std::vector<unsigned> seen;
  for (const auto& p : px) {
    unsigned k = (p.r << 16) | (p.g << 8) | p.b;
    bool found = false;
    for (auto v : seen) {
      if (v == k) { found = true; break; }
    }
    if (!found && seen.size() < 4096) seen.push_back(k);
  }
  return (int)seen.size();
}

}  // namespace

int main(int argc, char** argv) {
  // MUST be first: ReactNativeFeatureFlags::override() throws once any flag has
  // been read, and plenty of construction paths read one.
  rni::installFeatureFlags();

  std::string bundlePath, appName, screenshot;
  std::string colorScheme = "light";
  std::string initialUrl;
  bool headless = false;
  bool probeBanner = true;
  bool logMutations = false;
  bool listModules = false;
  bool testOpenUrl = false;
  int width = 400, height = 300;
  // Arbitrary pixel probes, so a gate can assert the geometry ITS fixture
  // declares instead of whatever probes happen to be hardcoded here. Each
  // prints `probe=<x>,<y> rgb=r,g,b`.
  std::vector<std::pair<int, int>> probes;
  // Rectangles in which to count NON-BACKGROUND pixels. Text is probed this way
  // rather than by exact pixel because glyph rasterisation is not byte-stable
  // across font stacks — but "is there ink in the band where the label belongs"
  // is, and it still fails when text does not render.
  struct InkBand { int x, y, w, h; };
  std::vector<InkBand> inkBands;

  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&](const char* what) -> std::string {
      if (i + 1 >= argc) {
        fprintf(stderr, "rn-impeller: %s requires a value\n", what);
        exit(2);
      }
      return argv[++i];
    };
    if (a == "--bundle") bundlePath = next("--bundle");
    else if (a == "--app-name") appName = next("--app-name");
    else if (a == "--screenshot") screenshot = next("--screenshot");
    else if (a == "--headless") headless = true;
    else if (a == "--log-mutations") logMutations = true;
    else if (a == "--list-modules") listModules = true;
    else if (a == "--test-openurl") testOpenUrl = true;
    else if (a == "--color-scheme") colorScheme = next("--color-scheme");
    else if (a == "--initial-url") initialUrl = next("--initial-url");
    else if (a == "--probe-banner") probeBanner = (next("--probe-banner") != "off");
    else if (a == "--width") width = atoi(next("--width").c_str());
    else if (a == "--height") height = atoi(next("--height").c_str());
    else if (a == "--probe") {
      std::string v = next("--probe");
      auto comma = v.find(',');
      if (comma == std::string::npos) {
        fprintf(stderr, "rn-impeller: --probe wants x,y (got %s)\n", v.c_str());
        return 2;
      }
      probes.emplace_back(atoi(v.substr(0, comma).c_str()),
                          atoi(v.substr(comma + 1).c_str()));
    }
    else if (a == "--ink-band") {
      // x,y,w,h
      std::string v = next("--ink-band");
      int f[4] = {0, 0, 0, 0};
      size_t pos = 0;
      bool ok = true;
      for (int k = 0; k < 4; ++k) {
        if (pos > v.size()) { ok = false; break; }
        auto c = v.find(',', pos);
        std::string part = v.substr(pos, c == std::string::npos ? c : c - pos);
        if (part.empty()) { ok = false; break; }
        f[k] = atoi(part.c_str());
        pos = (c == std::string::npos) ? v.size() + 1 : c + 1;
      }
      if (!ok) {
        fprintf(stderr, "rn-impeller: --ink-band wants x,y,w,h (got %s)\n", v.c_str());
        return 2;
      }
      inkBands.push_back(InkBand{f[0], f[1], f[2], f[3]});
    }
    else if (a == "--help" || a == "-h") { Usage(); return 0; }
    // Unknown flags are ignored on purpose: the CLI forwards user args through.
  }

  // Both of these are self-contained diagnostics that take NO bundle, so they
  // dispatch before the --bundle/--app-name requirement. --test-openurl has no
  // side effect at all: it exercises the predicate that protects the Windows
  // opener, on the platform that actually builds today.
  if (testOpenUrl) return rni::runOpenUrlSelfTest();
  if (listModules) return ListModules();

  if (bundlePath.empty() || appName.empty()) {
    Usage();
    return 2;
  }
  if (!IsAbsolute(bundlePath)) {
    fprintf(stderr,
            "rn-impeller: FATAL: --bundle must be an ABSOLUTE path "
            "(no CWD fallback exists)\n");
    return 1;
  }

  std::string bundle;
  if (!ReadFile(bundlePath, &bundle)) {
    fprintf(stderr, "rn-impeller: FATAL: cannot read bundle at %s\n",
            bundlePath.c_str());
    return 1;
  }
  const bool shimOk = bundle.find(kShimMarker) != std::string::npos;
  const size_t bundleSize = bundle.size();  // captured before the move below
  printf("rn-impeller: app=%s\n", appName.c_str());
  printf("rn-impeller: bundle=%s (%zu bytes)\n", bundlePath.c_str(), bundle.size());
  printf("rn-impeller: shim_marker=%s\n", shimOk ? "PRESENT" : "MISSING");
  printf("rn-impeller: headless=%s\n", headless ? "yes" : "no");
  fflush(stdout);

  if (!headless) {
    // Windowed WSI is a later phase. Say so rather than opening nothing and
    // exiting zero.
    fprintf(stderr,
            "rn-impeller: windowed mode is not implemented yet. "
            "Re-run with --headless.\n");
    return 3;
  }

  rni::HeadlessSurface surface;
  std::string error;
  if (!surface.init(width, height, &error)) {
    fprintf(stderr, "rn-impeller: FATAL: %s\n", error.c_str());
    return 1;
  }

  int painted = 0;
  size_t nodeCount = 0;
  {
    rni::SceneGraph sceneGraph(surface.typography());
    rni::ReactHost host;
    host.setKnownComponents(rni::FabricHost::knownComponentNames());
    host.displayMetrics()->set((float)width, (float)height, 1.0f);
    // Seed platform-module state BEFORE the bundle evaluates. Appearance is
    // read at module scope by RN's Appearance.js, so setting it after the
    // bundle runs would be read too late and look like the prop being ignored.
    host.appearance()->set(colorScheme);
    *host.initialUrl() = initialUrl;

    // Fabric must be up BEFORE the bundle evaluates: the Scheduler installs
    // UIManagerBinding through the unbuffered executor, and ReactFabric reads
    // global.nativeFabricUIManager the moment it initialises.
    rni::FabricHost fabric(host.instance(), &sceneGraph, surface.typography(),
                           logMutations, host.displayMetrics());

    host.runScript(std::move(bundle), "file://" + bundlePath);
    // Let the bundle finish evaluating (AppRegistry.registerComponent) before
    // asking for the surface, otherwise runApplication names a module that is
    // not registered yet.
    host.waitForJsIdle(10000);

    fabric.startSurface(appName, 1, (float)width, (float)height);
    // React renders, Fabric commits, the delegate applies mutations — all on
    // the JS thread. Idle means that whole chain has drained.
    host.waitForJsIdle(10000);

    nodeCount = sceneGraph.nodeCount();
    printf("rn-impeller: scene_nodes=%zu\n", nodeCount);
    // Side effects the modules recorded, so a gate can assert that JS actually
    // REACHED native rather than merely that the app rendered something.
    printf("rn-impeller: alerts_shown=%zu\n", host.alerts()->count());
    // Always emitted, not gated behind --log-mutations: a gate needs the frames
    // to prove LAYOUT, and painted pixels alone cannot (a 0x0-measured <Text>
    // still paints its glyphs).
    fputs(sceneGraph.frameReport().c_str(), stdout);
    if (logMutations) {
      printf("rn-impeller: scene=%s\n", sceneGraph.describe().c_str());
    }
    fflush(stdout);

    ImpellerDisplayListBuilder builder = ImpellerDisplayListBuilderNew(nullptr);
    painted = sceneGraph.paint(builder);
    if (probeBanner) {
      DrawProbeBanner(builder, shimOk, bundleSize, width, height);
    }
    ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(builder);
    if (dl == nullptr) {
      fprintf(stderr, "rn-impeller: FATAL: CreateDisplayListNew returned null\n");
      return 1;
    }
    if (!surface.drawDisplayList(dl)) {
      fprintf(stderr, "rn-impeller: FATAL: SurfaceDrawDisplayList failed\n");
      return 1;
    }
    ImpellerDisplayListRelease(dl);
    ImpellerDisplayListBuilderRelease(builder);
  }

  std::vector<rni::Px> px;
  if (!surface.readPixels(&px)) {
    fprintf(stderr, "rn-impeller: FATAL: glReadPixels failed\n");
    return 1;
  }
  auto at = [&](int x, int y) -> rni::Px { return px[(size_t)y * width + x]; };

  printf("rn-impeller: painted_nodes=%d\n", painted);
  if (probeBanner) {
    rni::Px s = at(70, 70);
    printf("rn-impeller: status_swatch_rgb=%d,%d,%d\n", s.r, s.g, s.b);
    // Inside the rounded rect's bounding box but OUTSIDE its corner, so the
    // backdrop must show through. This is the probe that catches a subtle
    // wrong-shape regression that a swatch-only gate cannot.
    rni::Px c = at(202, 22);
    printf("rn-impeller: rrect_corner_rgb=%d,%d,%d\n", c.r, c.g, c.b);
  }
  printf("rn-impeller: distinct_colors=%d\n", CountDistinctColors(px));

  for (const auto& [px_x, px_y] : probes) {
    if (px_x < 0 || px_y < 0 || px_x >= width || px_y >= height) {
      printf("rn-impeller: probe=%d,%d OUT_OF_BOUNDS\n", px_x, px_y);
      continue;
    }
    rni::Px p = at(px_x, px_y);
    printf("rn-impeller: probe=%d,%d rgb=%d,%d,%d\n", px_x, px_y, p.r, p.g, p.b);
  }

  for (const auto& band : inkBands) {
    int ink = 0, total = 0;
    for (int yy = band.y; yy < band.y + band.h; ++yy) {
      for (int xx = band.x; xx < band.x + band.w; ++xx) {
        if (xx < 0 || yy < 0 || xx >= width || yy >= height) continue;
        ++total;
        rni::Px p = at(xx, yy);
        // "Not background": anything meaningfully darker than white. The
        // fixture's label is black on white, and anti-aliased glyph edges count
        // as ink too — which is the point, since a band that only matched pure
        // black would fail on a correctly-rendered thin font.
        if (p.r < 200 || p.g < 200 || p.b < 200) ++ink;
      }
    }
    printf("rn-impeller: ink_band=%d,%d,%d,%d ink=%d of %d\n", band.x, band.y,
           band.w, band.h, ink, total);
  }

  if (!screenshot.empty()) {
    if (rni::HeadlessSurface::writePpm(screenshot, px, width, height)) {
      printf("rn-impeller: screenshot=%s\n", screenshot.c_str());
    } else {
      fprintf(stderr, "rn-impeller: WARN: cannot write screenshot %s\n",
              screenshot.c_str());
    }
  }

  if (!shimOk) {
    printf("RN_IMPELLER_FAIL (packaging shim marker absent from bundle)\n");
    return 4;
  }
  printf("RN_IMPELLER_RENDER_OK app=%s\n", appName.c_str());
  fflush(stdout);
  return 0;
}
