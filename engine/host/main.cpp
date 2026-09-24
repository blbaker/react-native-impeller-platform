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
// The offscreen surface, per platform. Both classes expose the SAME contract
// (init / drawDisplayList / readPixels / writePpm / context / typography), so
// everything below this line is platform-neutral and there is exactly ONE
// `#ifdef _WIN32` in the host rather than one per call site.
//
// They are separate classes rather than one file with internal branches because
// the difference is not a few calls — it is the entire context-acquisition
// path: Mesa surfaceless EGL with link-time GL on Linux, versus ANGLE loaded by
// LoadLibrary with a pbuffer and D3D11 underneath on Windows.
#ifdef _WIN32
#include "host/WinGLSurface.h"
#else
#include "host/HeadlessSurface.h"
#endif
#if RNI_WITH_WINDOW
#include "host/GlfwSurface.h"
#include <chrono>
#include <thread>
#endif
// Header-only and platform-free on purpose: the backing-scale decision has to
// be testable (--test-pointscale) on hosts that have no window at all.
#include "host/PointScale.h"
#include "scenegraph/CaretBlink.h"
#include "impeller.h"
#include "runtime/FeatureFlags.h"
#include "runtime/ReactHost.h"
#include "scenegraph/SceneGraph.h"

namespace {

#ifdef _WIN32
using PlatformSurface = rni::WinGLSurface;
#else
using PlatformSurface = rni::HeadlessSurface;
#endif


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
          "                   [--scale N]  device pixels per point. HEADLESS: the\n"
          "                     only input, default 1. WINDOWED: an OVERRIDE of the\n"
          "                     display's real fb/window ratio -- omit it to drive\n"
          "                     the natural path a shipped app takes. Passing it on\n"
          "                     a 2x display makes layout points != screen coords,\n"
          "                     so a probe asserting arrival == the clicked point\n"
          "                     reads the deliberate override as an engine defect.\n"
          "                     The startup line states which is in force:\n"
          "                     '(--scale override)' vs '(from framebuffer)'.\n"
          "                   [--click-after-frames N:X,Y]  (windowed; screen coords)\n"
          "                   [--scroll-after-frames N:X,Y,dx,dy]  (windowed;\n"
          "                     screen coords, GLFW notch convention: dy>0 is\n"
          "                     wheel-away/scroll-up. Synthetic -- it does NOT\n"
          "                     prove glfwSetScrollCallback is registered.)\n"
          "                   [--log-mutations] [--color-scheme light|dark]\n"
          "                   [--supersample-rnsvg N]  offscreen N x SVG AA;\n"
          "                     default 4 on darwin, 0 (off) elsewhere\n"
          "                   [--initial-url URL]\n"
          "                   [--window] [--frames N] [--screenshot-after MS]\n"
          "                   [--screenshot-first <file.ppm>]\n"
          "       rn-impeller --list-modules   (module seam manifest; no bundle)\n"
          "       rn-impeller --test-openurl   (URL predicate self-test)\n"
          "       rn-impeller --test-urlparse  (Networking URL parse self-test)\n"
          "       rn-impeller --test-http      (Networking loopback GET/POST self-test)\n");
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

  // ⛔ FABRIC MUST BE UP BEFORE ANY MODULE IS TOUCHED, AND ONLY ENG-06 MADE
  // THAT TRUE. Enumerating the registry evaluates JS that reads
  // `nativeModuleProxy[name]`, which CONSTRUCTS each module. Every module
  // before NativeAnimatedModule was self-contained, so a bare ReactHost with
  // no renderer was enough. AnimatedModule is not: its
  // installJSIBindingsWithRuntime calls provider->getOrCreate(), which does
  //
  //     UIManagerBinding::getBinding(runtime)->getUIManager()
  //
  // and dereferences the result. With no Scheduler there IS no binding, so
  // that is a null dereference -- the manifest died mid-list with SIGSEGV and
  // no message, taking the ci-p4 / ci-p10 MODULE_MANIFEST_END assertion with
  // it. Bringing up a real surface + SceneGraph + FabricHost here is not
  // scaffolding for the sake of it: it makes --list-modules enumerate modules
  // under the same conditions a real app gives them, which is the only version
  // of the manifest worth diffing against the shipped JS.
  PlatformSurface surface;
  std::string surfaceError;
  if (!surface.init(64, 64, &surfaceError)) {
    fprintf(stderr, "rn-impeller: --list-modules: surface init failed: %s\n",
            surfaceError.c_str());
    return 1;
  }
  rni::SceneGraph sceneGraph(surface.typography());
  rni::FabricHost fabric(host.instance(), &sceneGraph, surface.typography(),
                         /*logMutations*/ false, host.displayMetrics());

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

#if RNI_WITH_WINDOW
// The windowed repaint loop.
//
// ⛔ WHY THIS REPAINTS UNCONDITIONALLY EVERY FRAME, RATHER THAN ONLY WHEN
// FABRIC HAS A PENDING MUTATION: `FabricHost.cpp:189` passes `nullptr` for
// the animation delegate (P9-C, not this phase), so there is currently no
// signal that would tell this loop "something changed, repaint" versus
// "nothing changed, skip". Two ways to close that gap: (a) drive repaints
// from vsync (what this does — call paintFrame() every time glfwSwapBuffers
// would run anyway) or (b) drive them from Fabric mutation notifications
// once P9-C wires a real animation delegate. Choosing (a) here is NOT
// picking that architecture: an unconditional per-frame repaint is exactly
// as compatible with a future mutation-driven skip-if-unchanged optimisation
// as it is with staying vsync-driven forever, so nothing about P9-C is
// foreclosed. See docs/STATE.md "Open questions" if that changes.
int RunWindowed(const std::string& bundlePath, const std::string& appName,
                std::string bundle, size_t nodeReportOnly, size_t bundleSize,
                const std::string& colorScheme, const std::string& initialUrl,
                int width, int height, float pointScale, bool logMutations,
                int frames, int screenshotAfterMs,
                const std::string& screenshotPath,
                const std::string& screenshotFirstPath,
                bool pointScaleGiven, int resizeAfterFrames, int resizeToW,
                int resizeToH, int stallAfterFrames, int stallMs,
                int clickAfterFrames, double clickX, double clickY,
                int scrollAfterFrames, double scrollX, double scrollY,
                double scrollDx, double scrollDy,
                int hoverAfterFrames,
                const std::vector<std::pair<double, double>>& hoverPoints,
                bool hoverLeaveAtEnd, int supersampleRnsvg) {
  (void)nodeReportOnly;
  (void)bundleSize;
  rni::GlfwSurface surface;
  std::string error;
  if (!surface.init(width, height, &error)) {
    fprintf(stderr, "rn-impeller: FATAL: %s\n", error.c_str());
    return 1;
  }

  // ⛔ THE WINDOW, NOT THE CLI, DECIDES THE PIXEL SIZE AND THE SCALE.
  // --width/--height went to glfwCreateWindow, which treats them as SCREEN
  // COORDINATES (points). On a 2x display the framebuffer that comes back is
  // twice as large in each axis. Continuing to use the CLI numbers here —
  // which is what this function did until now, with pointScale stuck at its
  // 1.0 default — laid the app out in `width` x `height` POINTS and
  // rasterised at 1x, so the content filled only the top-left quarter of the
  // framebuffer and every glyph was rasterised for a 1x display. On screen
  // that reads as "pixelated / half-size next to a native window", not as a
  // layout bug, which is why it survived the windowed gates.
  //
  // From here down, pxWidth/pxHeight are the surface's REAL pixel size and
  // pointScale is the REAL backing scale; layout points are pixels/scale, the
  // same relationship the headless path already documents at --width.
  const int pxWidth = surface.width();
  const int pxHeight = surface.height();
  pointScale = rni::DeriveWindowPointScale(pxWidth, surface.pointWidth(),
                                           pointScale, pointScaleGiven);
  printf("rn-impeller: window px=%dx%d points=%.1fx%.1f scale=%.2f%s\n",
         pxWidth, pxHeight, (float)pxWidth / pointScale,
         (float)pxHeight / pointScale, pointScale,
         pointScaleGiven ? " (--scale override)" : " (from framebuffer)");
  fflush(stdout);

  rni::SceneGraph sceneGraph(surface.typography());
  // ENG item 2. Wire the supersample render context (the surface's own
  // ImpellerContext — same GL sharegroup the offscreen FBO needs) and N. On
  // Windows/Android the offscreen path is compiled out, so these are inert.
  sceneGraph.setRenderContext(surface.context());
  sceneGraph.setSupersample(supersampleRnsvg);
  // ENG item 2b — the root supersample offscreen is sized N x this. Device
  // pixels (surface.width()/height()), re-set on resize below.
  sceneGraph.setSurfaceSize(surface.width(), surface.height());
  // The cursor conversion divides by this. Set from the SAME derived value the
  // layout uses, and re-set on every resize below, so a click can never be
  // converted with a scale the painter is no longer using.
  surface.setPointScale(pointScale);
  rni::ReactHost host;
  host.setKnownComponents(rni::FabricHost::knownComponentNames());
  host.displayMetrics()->set((float)pxWidth / pointScale,
                             (float)pxHeight / pointScale, pointScale);
  host.appearance()->set(colorScheme);
  *host.initialUrl() = initialUrl;

  rni::FabricHost fabric(host.instance(), &sceneGraph, surface.typography(),
                         logMutations, host.displayMetrics());

  host.runScript(std::move(bundle), "file://" + bundlePath);
  host.waitForJsIdle(10000);
  // startSurface takes DEVICE PIXELS and divides by pointScale itself
  // (FabricHost.cpp:279) — so it gets the framebuffer size, not the request.
  fabric.startSurface(appName, 1, (float)pxWidth, (float)pxHeight, pointScale);
  host.waitForJsIdle(10000);

  printf("rn-impeller: scene_nodes=%zu\n", sceneGraph.nodeCount());
  printf("rn-impeller: supersample_rnsvg=%d\n", sceneGraph.supersample());
  fflush(stdout);

  // Incremented inside paintFrame at the present, so it counts FRAMES THAT
  // REACHED THE SCREEN. Declared before paintFrame because that lambda
  // captures it.
  int paintsTotal = 0;

  auto paintFrame = [&]() -> int {
    // ⛔ THE PAINT-IN-FLIGHT SCOPE GOES HERE, AT THE ONE SHARED BODY.
    // Both the frame loop and the window-refresh callback paint through this
    // lambda, so scoping the guard here is what makes it cover every paint
    // rather than only the callback's. surface.present() below is the call
    // that can re-enter: eglSwapBuffers -> CAMetalLayer update ->
    // -[NSView updateLayer] -> _glfwInputWindowDamage -> refresh callback.
    // With this scope live, that callback is dropped instead of starting a
    // second paint on top of this one.
    rni::GlfwSurface::PaintScope paintScope(&surface);
    ImpellerDisplayListBuilder builder = ImpellerDisplayListBuilderNew(nullptr);
    int painted = sceneGraph.paint(builder, pointScale);
    ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(builder);
    if (dl) {
      surface.drawDisplayList(dl);
      ImpellerDisplayListRelease(dl);
    }
    ImpellerDisplayListBuilderRelease(builder);
    surface.present();
    // ⛔ COUNTED HERE, AT THE PRESENT, NOT AT THE CALLER.
    // refreshPaints is derived from this counter, so "a frame was painted
    // during the stall" is measured at the only place a frame actually
    // reaches the screen. Counting in the refresh handler instead would let a
    // handler that increments a variable and never paints report success --
    // precisely the mark-only trap this fix exists to avoid, and exactly what
    // the M2 mutant in tools/mutation-verify-resize.sh does.
    ++paintsTotal;
    return painted;
  };

  auto start = std::chrono::steady_clock::now();
  bool capturedTimed = false;
  bool capturedFirst = false;
  int frameIndex = 0;
  // Paints produced from the GLFW window-refresh callback rather than from the
  // loop below. Printed at exit so a gate has a machine-readable signal that
  // the modal-loop path actually ran, instead of inferring it from a pixel
  // comparison that a lucky post-drag repaint would also satisfy.
  int refreshPaints = 0;

  // ⛔ SCALE AND SIZE ARE DECIDED ONCE AT WINDOW CREATION UNLESS THIS RUNS.
  // Everything above the loop ran exactly once. RN's own platforms do not
  // stop at detection: iOS reads UIScreen.mainScreen.scale then listens on
  // didUpdateDimensions, Android reads densityDpi then re-delivers on
  // configuration change. consumeDirty() is this engine's version of that
  // listener, and it is false on every frame that is not a resize, so the
  // steady-state cost is one relaxed atomic load.
  //
  // ⛔ ONE BODY, TWO CALLERS — DO NOT INLINE A SECOND COPY OF THIS.
  // It is called from the frame loop AND from the window-refresh callback
  // (which is the only caller that can run during a macOS modal resize drag).
  // Duplicating it would give the drag path its own copy of the
  // pointScaleGiven distinction below, and the mutation gate on
  // DeriveWindowPointScale would then only cover one of the two callers.
  auto applyResizeIfDirty = [&]() -> bool {
    if (!surface.consumeDirty()) return false;
    const int newPx = surface.width();
    const int newPy = surface.height();
    // ⛔ HONOUR THE OVERRIDE THE SAME WAY THE STARTUP PATH DOES.
    // pointScaleGiven, not `pointScale != 1.0f`: the default IS 1.0, so an
    // explicit `--scale 1` has to stay distinguishable from no flag at all
    // (D-46). Re-deriving through the same DeriveWindowPointScale the
    // startup path uses means a resize can never disagree with launch, and
    // the mutation gate on that function covers both callers.
    pointScale = rni::DeriveWindowPointScale(newPx, surface.pointWidth(),
                                             pointScale, pointScaleGiven);
    // ⛔ THE CURSOR CONVERSION MUST FOLLOW THE RESIZE, NOT LAG IT.
    // Dragging a window between a 2x and a 1x monitor changes pointScale
    // here; a stale copy inside the surface would then convert every
    // subsequent click by the OLD factor and quietly halve or double every
    // coordinate. Set through the same one derivation, at the same moment.
    surface.setPointScale(pointScale);
    // ENG item 2b — the root supersample offscreen must track the new
    // framebuffer, or it would supersample the old extent into the new one.
    sceneGraph.setSurfaceSize(newPx, newPy);
    const float newPointW = (float)newPx / pointScale;
    const float newPointH = (float)newPy / pointScale;

    // Dimensions.get('window') and the useWindowDimensions hook read this.
    host.displayMetrics()->set(newPointW, newPointH, pointScale);
    // And this re-constrains the LAYOUT. Without it the framebuffer and
    // Dimensions are both correct and every mounted view keeps the geometry
    // it had at launch, which is the half of the bug a screenshot of a
    // freshly-launched window can never show.
    fabric.updateSurface(1, (float)newPx, (float)newPy, pointScale);

    // ⛔ EMIT LAST. ORDER IS set -> resizeSurface -> emit, AND IT IS LOAD-BEARING.
    // Emitting first re-renders JS against the new Dimensions while Fabric
    // still holds the OLD layout constraint, committing one frame at a width
    // the surface does not have. That is a single wrong frame -- it survives a
    // screenshot gate, because by the time anything captures, the next frame
    // is correct.
    //
    // This is the crossing the whole suite was blind to: 16 of 16 probes would
    // pass on a build where the two lines above run and this one does not
    // (boundary-audit.py, boundary-crossing 0/16). Native geometry perfect,
    // JS never told.
    //
    // toDimensionsDynamic() rather than a hand-built object: Dimensions.js
    // requires the SAME metrics under both `window` and `screen`, plus
    // fontScale. Building it here would let the two shapes drift.
    host.deviceEvents()->emit("didUpdateDimensions",
                              host.displayMetrics()->toDimensionsDynamic());

    printf("rn-impeller: resize px=%dx%d points=%.1fx%.1f scale=%.2f%s\n",
           newPx, newPy, newPointW, newPointH, pointScale,
           pointScaleGiven ? " (--scale override)" : " (from framebuffer)");
    fflush(stdout);
    return true;
  };

  // ⛔ THE POST-RESIZE NODE COUNT, AND WHY IT NEEDS ITS OWN LINE.
  // scene_nodes is printed exactly twice: once after startSurface (line ~333)
  // and once in the headless summary. Neither observes a windowed resize, so a
  // gate grepping scene_nodes reads the SAME pre-resize number twice and
  // concludes "JS did not re-render" no matter what JS did. Measured
  // 2026-09-09: D4 reported 5 -> 5 against a build whose emit was confirmed
  // delivered, which is a false RED -- the instrument, not the subject.
  //
  // Counted after a JS-idle wait, because the emit is dispatched through the
  // BUFFERED executor: it is queued, not synchronous, so sampling on the same
  // turn reads the tree from before React re-rendered.
  auto reportNodesAfterResize = [&]() {
    host.waitForJsIdle(2000);
    printf("rn-impeller: scene_nodes_after_resize=%zu\n", sceneGraph.nodeCount());
    fflush(stdout);
  };

  // ⛔ THE CALLBACK MUST PAINT, NOT JUST MARK DIRTY.
  // During a macOS window-edge drag, glfwPollEvents() never returns, so the
  // loop below cannot consume anything. Raising a flag from in here would
  // change nothing at all — the consumer is blocked. A frame has to be
  // rendered AND presented from within this callback, which is why it calls
  // paintFrame() itself.
  //
  // JS is NOT pumped here on purpose. Fabric's layout re-constrain in
  // applyResizeIfDirty is synchronous on the shadow tree, which is what makes
  // the breakpoint cross visible mid-drag; running the JS scheduler from
  // inside AppKit's modal loop would re-enter the runtime from a nested event
  // loop for a benefit the drag does not need.
  surface.setRefreshHandler([&]() {
    applyResizeIfDirty();
    paintFrame();
  });

  // ⛔ THE WINDOWED PATH'S ONLY ROUTE INTO dispatchTouch.
  // Before this, dispatchTouch had exactly one caller in the whole binary:
  // the headless `--tap` probe at main.cpp:885, which is PAST THE END of this
  // function (RunWindowed spans 259..547; main() calls it at 777). So the
  // input tier was complete, gated and unreachable in `--window` mode, which
  // is why hostapp's onPress handlers were inert on screen while ci-input.sh
  // stayed green.
  //
  // x/y arrive in LAYOUT POINTS — the conversion from GLFW's screen
  // coordinates lives in GlfwSurface::dispatchCursorPoint so that both the
  // real callback and the test hook share it and neither can drift.
  //
  // ⛔ NO waitForJsIdle HERE. dispatchTouch hops to the JS thread through the
  // RuntimeScheduler and returns; blocking the event thread for the handler
  // would stall the frame loop (and, on darwin, could be entered from inside
  // AppKit's modal loop). The next frame picks up whatever the handler
  // mutated, which is how a real UI toolkit behaves.
  int touchHits = 0;
  int touchDowns = 0;
  surface.setMouseButtonHandler([&](float x, float y, bool down) {
    // ENG-DRAG (P0). A press begins a capture and a release ends it, so every
    // cursor-move in between (delivered by the hover handler below) routes to
    // the pressed control, not to whatever is under the cursor now. Without
    // this the drag path re-hit-tested each move and a slider dragged past its
    // track, or a button pressed and slid off, lost the gesture.
    const int hit = down ? fabric.beginTouchCapture(x, y)
                         : fabric.endTouchCapture(x, y);
    if (down) {
      // <TextInput>. ENG-01b. A press also (re)assigns keyboard focus: click a
      // field to edit it, click elsewhere to blur. This must run on the DOWN so
      // the caret appears on the same click that a user expects it to, and is
      // separate from the touch dispatch above -- a field both receives the
      // press (for onPressIn-style handlers) AND takes focus.
      const int focused = fabric.focusTextInputAt(x, y);
      printf("rn-impeller: textinput_focus=%d at=%.1f,%.1f\n", focused, x, y);
      ++touchDowns;
      if (hit) ++touchHits;
      // Machine-readable, and printed for the DOWN only: a gate asserting on
      // both phases would double-count one click. touch_hit=0 is a real,
      // meaningful outcome (the user clicked empty space), so it is printed
      // rather than suppressed — silence here would be indistinguishable from
      // the callback never firing, which is the exact bug being fixed.
      printf("rn-impeller: touch_down hit=%d at=%.1f,%.1f\n", hit, x, y);
      fflush(stdout);
    }
  });

  // <ScrollView>. ENG-02. Same shape and the same threading argument as the
  // touch handler above: dispatch and return, never block the event thread.
  //
  // scroll_hit=0 is printed too, for the same reason touch_hit=0 is: "the wheel
  // was over nothing scrollable" and "the callback never fired" are different
  // facts, and suppressing the first makes them look identical to a gate.
  int scrollHits = 0;
  int scrollEvents = 0;
  surface.setScrollHandler([&](float x, float y, float dx, float dy) {
    const int hit = fabric.dispatchScroll(x, y, dx, dy);
    ++scrollEvents;
    if (hit) ++scrollHits;
    printf("rn-impeller: scroll hit=%d at=%.1f,%.1f dx=%.1f dy=%.1f\n", hit, x, y,
           dx, dy);
    fflush(stdout);
  });

  // ENG-09 hover/cursor. The windowed path's only route into dispatchHover,
  // same shape and threading argument as the touch and scroll handlers above:
  // resolve on the event thread, dispatch onto the JS thread, return.
  //
  // ⛔ THE PER-MOVE PATH IS QUIET. A machine-readable line is printed ONLY on a
  // transition -- hover_enter when a new tag is entered, hover_leave when the
  // old one is left, cursor= when the shape changes -- never once per
  // mouse-move event. A mouse dragged across one button emits one enter line,
  // not hundreds, so a gate can count transitions and a human's move does not
  // flood the log. dispatchHover returns 0/0 for entered/left when the tag did
  // not change, which is what makes the common case silent.
  int lastLoggedCursor = -1;
  surface.setHoverHandler([&](float x, float y) -> int {
    // ENG-DRAG (P0). A cursor-move while a button is held is a DRAG, not a
    // hover: route it to the captured tag (the pressed control) as a Move, and
    // suppress hover enter/leave entirely -- a control being dragged does not
    // fire pointerenter on whatever the cursor passes over. The cursor shape is
    // held at the drag's grabbing shape by the mac's NSCursor path (mac-patches
    // 2c0ed10); returning the last shape keeps this path from fighting it.
    if (fabric.isTouchCaptured()) {
      fabric.dispatchCapturedMove(x, y);
      return lastLoggedCursor < 0 ? 0 : lastLoggedCursor;
    }
    const auto r = fabric.dispatchHover(x, y);
    bool logged = false;
    if (r.left) {
      printf("rn-impeller: hover_leave tag=%d\n", r.left);
      logged = true;
    }
    if (r.entered) {
      printf("rn-impeller: hover_enter tag=%d\n", r.entered);
      logged = true;
    }
    // Cursor line only when the shape actually changes, for the same reason
    // the transitions are: a gate wants "the shape became a hand", not a line
    // per pixel of travel. The names are the ones the peer's gate parses.
    if (r.cursorKind != lastLoggedCursor) {
      const char* name = r.cursorKind == 1   ? "hand"
                         : r.cursorKind == 2 ? "ibeam"
                                             : "arrow";
      printf("rn-impeller: cursor=%s\n", name);
      lastLoggedCursor = r.cursorKind;
      logged = true;
    }
    if (logged) fflush(stdout);
    return r.cursorKind;
  });

  // ENG-09 hover/cursor. The other half: clear the hovered tag when the cursor
  // leaves the window, so a control does not stay hovered after the mouse
  // exits. Logs the leave as a transition, same format as the move path.
  surface.setCursorLeaveHandler([&]() {
    const int left = fabric.clearHover();
    if (left) {
      printf("rn-impeller: hover_leave tag=%d\n", left);
      // Only emit a cursor line if the shape actually changes to arrow -- if
      // the box being left was already arrow, a redundant cursor=arrow would
      // be a per-event line, the exact noise this path avoids elsewhere.
      if (lastLoggedCursor != 0) {
        printf("rn-impeller: cursor=arrow\n");
        lastLoggedCursor = 0;
      }
      fflush(stdout);
    }
  });

  // <TextInput>. ENG-01b. Keyboard -> focused field. The char handler carries a
  // decoded codepoint (a real typed character); the key handler carries the
  // control keys (Backspace, Enter) that never reach the char callback. Both
  // route into FabricHost::dispatchKey, which no-ops when no field is focused --
  // so a keystroke with nothing focused is silently ignored, exactly as a
  // desktop app does. Both print a machine-readable line for the gate.
  surface.setCharHandler([&](unsigned int codepoint) {
    if (!fabric.hasTextInputFocus()) return;
    const int tag =
        fabric.dispatchKey(rni::FabricHost::KeyAction::InsertChar, codepoint);
    printf("rn-impeller: key_char cp=%u tag=%d\n", codepoint, tag);
    fflush(stdout);
  });
  surface.setKeyHandler([&](rni::GlfwSurface::EditKey key, bool shift) {
    if (!fabric.hasTextInputFocus()) return;
    rni::FabricHost::KeyAction act;
    if (key == rni::GlfwSurface::EditKey::Backspace) {
      act = rni::FabricHost::KeyAction::Backspace;
    } else {
      // Shift+Enter is the multiline newline (chat composer, comments); a bare
      // Enter submits. The multiline buffer path is a later arm -- for now the
      // shift case is routed as Newline and dispatchKey treats it as submit,
      // called out rather than silently swallowed.
      act = shift ? rni::FabricHost::KeyAction::Newline
                  : rni::FabricHost::KeyAction::Submit;
    }
    const int tag = fabric.dispatchKey(act, 0);
    printf("rn-impeller: key_ctrl key=%d tag=%d\n", (int)key, tag);
    fflush(stdout);
  });

  // Reads the framebuffer and writes a PPM. Shared by the frame-0 and the
  // timed capture so the two images are produced by literally the same code
  // path -- if they differed in how they were read back, a difference between
  // them would not prove anything about repainting.
  auto capture = [&](const std::string& path, const char* label) {
    if (path.empty()) return;
    std::vector<rni::Px> px;
    if (!surface.readPixels(&px)) return;
    if (!rni::GlfwSurface::writePpm(path, px, surface.width(), surface.height()))
      return;
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                  std::chrono::steady_clock::now() - start)
                  .count();
    printf("rn-impeller: %s=%s frame=%d elapsed_ms=%lld\n", label, path.c_str(),
           frameIndex, (long long)ms);
    fflush(stdout);
  };

  while (!surface.shouldClose()) {
    surface.pollEvents();

    // The loop's caller of the shared resize body. This is the path that runs
    // in the normal (non-drag) case; the window-refresh callback installed
    // above is the path that runs when this loop is blocked inside
    // pollEvents(). Both go through applyResizeIfDirty, deliberately.
    applyResizeIfDirty();

    // Test hook: drive a resize from inside the process at a known frame.
    // There is no headless way to make a window manager resize a window, and
    // glfwSetWindowSize enters the SAME framebuffer-size callback a user drag
    // does, so this is the only way the feature is gateable without a human
    // and a mouse.
    if (resizeAfterFrames > 0 && frameIndex == resizeAfterFrames) {
      printf("rn-impeller: resize_requested %dx%d points\n", resizeToW,
             resizeToH);
      fflush(stdout);
      surface.requestSize(resizeToW, resizeToH);
    }

    // Sampled a few frames AFTER the request, not on the same frame: the
    // resize lands via the framebuffer callback and the emit is queued on the
    // buffered executor, so React has not re-rendered yet at frame N.
    if (resizeAfterFrames > 0 && frameIndex == resizeAfterFrames + 5) {
      reportNodesAfterResize();
    }

    // ⛔ THE HOOK THAT MAKES THE ACTUAL BUG GATEABLE.
    // --resize-after-frames proves the resize BODY works, because
    // glfwSetWindowSize enters the framebuffer-size callback. It cannot prove
    // the thing being fixed: glfwSetWindowSize does NOT enter macOS's modal
    // resize loop, so under it the frame loop keeps spinning and consumeDirty
    // is reachable on the very next iteration. A gate built on it alone passes
    // just as happily with the refresh callback deleted.
    //
    // This hook reproduces the DEFINING PROPERTY of the drag instead: the loop
    // body becomes unreachable while GLFW keeps dispatching event callbacks.
    // If a frame is painted during the stall, it can ONLY have come from the
    // window-refresh callback, because nothing else is running. That is the
    // fix, isolated. Ordered AFTER the resize hook and at the SAME frame N so
    // the resize is REQUESTED and then never returned to: pass
    // `--resize-after-frames N:WxH --stall-after-frames N:MS` with the same N.
    // With different Ns the loop consumes the resize normally before the stall
    // begins and painted_during is 0 whether or not the fix is present.
    if (stallAfterFrames > 0 && frameIndex == stallAfterFrames) {
      const int before = paintsTotal;
      printf("rn-impeller: stall_begin ms=%d refresh_paints=%d\n", stallMs,
             refreshPaints);
      fflush(stdout);
      auto stallUntil = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(stallMs);
      while (std::chrono::steady_clock::now() < stallUntil) {
        // The frame loop body is deliberately NOT run here. Only GLFW's event
        // dispatch happens, exactly as inside AppKit's modal resize loop.
        surface.waitEvents(0.02);
      }
      // Every paint that landed while the loop body was unreachable came from
      // the refresh callback -- nothing else could have produced one.
      refreshPaints += paintsTotal - before;
      printf("rn-impeller: stall_end refresh_paints=%d painted_during=%d\n",
             refreshPaints, paintsTotal - before);
      fflush(stdout);
    }

    // ENG-06: advance RN's animation engine once per frame, BEFORE painting,
    // so this frame shows the value this tick produced. Near-free when nothing
    // is animating (one atomic load) -- see ReactHost::pumpNativeAnimated.
    host.pumpNativeAnimated();

    int painted = paintFrame();
    ++frameIndex;
    if (frameIndex == 1) printf("rn-impeller: painted_nodes=%d\n", painted);

    // ⛔ SYNTHETIC-CLICK HOOK — AND IT IS DELIBERATELY THE WEAKER EVIDENCE.
    // This calls the handler through GlfwSurface::synthesiseClick, so it
    // proves the CONVERSION, the dispatch, and the JS handler. It does NOT
    // prove glfwSetMouseButtonCallback is registered — deleting that
    // registration leaves this hook passing. tools/ci-window-input.sh
    // therefore pairs it with a REAL XTest pointer click, and the mutation
    // gate asserts that deleting the registration kills the XTest assertion
    // specifically. Stated here so nobody later mistakes this for the whole
    // proof; it is the half that runs where there is no X server to drive.
    if (clickAfterFrames > 0 && frameIndex == clickAfterFrames) {
      printf("rn-impeller: click_requested at=%.1f,%.1f (screen coords)\n",
             clickX, clickY);
      fflush(stdout);
      surface.synthesiseClick(clickX, clickY);
      // dispatchTouch is asynchronous by design; returning to the loop
      // immediately and then exiting at --frames would end the process before
      // any handler ran, making a WORKING dispatch look dead. Same reasoning
      // as the headless --tap probe's waitForJsIdle.
      host.waitForJsIdle(5000);
    }

    // ⛔ SYNTHETIC-SCROLL HOOK — WEAKER EVIDENCE, EXACTLY LIKE THE CLICK ONE.
    // Routes through GlfwSurface::synthesiseScroll, so it proves the
    // conversion, the sign flip, the SceneGraph offset and the JS onScroll. It
    // does NOT prove glfwSetScrollCallback is registered: deleting that
    // registration leaves this hook green. tools/ci-scroll.sh pairs it with a
    // REAL XTest wheel event for the registration arm.
    if (scrollAfterFrames > 0 && frameIndex == scrollAfterFrames) {
      printf("rn-impeller: scroll_requested at=%.1f,%.1f dx=%.1f dy=%.1f (screen "
             "coords, GLFW notch convention)\n",
             scrollX, scrollY, scrollDx, scrollDy);
      fflush(stdout);
      surface.synthesiseScroll(scrollX, scrollY, scrollDx, scrollDy);
      // Same reason the click hook waits: onScroll is dispatched onto the JS
      // thread, so exiting at --frames without draining it would make a working
      // emitter look dead.
      host.waitForJsIdle(5000);
    }

    // ENG-09 hover/cursor. Synthetic-hover hook, and DELIBERATELY THE WEAKER
    // EVIDENCE, exactly like the click and scroll hooks. It routes through
    // GlfwSurface::synthesiseHover, so it proves the conversion, the retained
    // hovered-tag transition logic, the pointerenter/leave dispatch and the
    // cursor-kind resolution. It does NOT prove glfwSetCursorPosCallback is
    // registered -- deleting that registration leaves this hook passing.
    // The gate's NEGATIVE ARM (registration removed, a REAL OS motion event
    // over the same point, asserting NO hover lines) is what proves the
    // registration; this hook is the half that runs where there is no display.
    //
    // One point is consumed per frame starting at hoverAfterFrames, so a
    // sequence walks enter -> move-within -> move-to-another as distinct frames
    // rather than a single warp, which is how the "quiet within one view"
    // property becomes observable: a mid-view move emits no line.
    if (hoverAfterFrames > 0 && frameIndex >= hoverAfterFrames &&
        !hoverPoints.empty()) {
      const size_t idx = (size_t)(frameIndex - hoverAfterFrames);
      if (idx < hoverPoints.size()) {
        const auto& p = hoverPoints[idx];
        printf("rn-impeller: hover_requested at=%.1f,%.1f (screen coords)\n",
               p.first, p.second);
        fflush(stdout);
        surface.synthesiseHover(p.first, p.second);
        host.waitForJsIdle(5000);
      } else if (idx == hoverPoints.size() && hoverLeaveAtEnd) {
        // After the last point, optionally drive the cursor OUT of the window,
        // exercising the cursor-enter(leave) path and asserting the hovered
        // control does not stay hovered.
        printf("rn-impeller: hover_leave_requested (cursor exits window)\n");
        fflush(stdout);
        surface.synthesiseCursorLeave();
        host.waitForJsIdle(5000);
      }
    }


    // ⛔ The frame-0 capture is what makes an animation gate possible at all.
    // A single timed screenshot proves only that SOMETHING was drawn; it
    // cannot distinguish a live repaint loop from a static engine redrawing
    // identical pixels forever. Two captures from ONE run, compared, can.
    // Taken AFTER the first paint so it is a real rendered frame rather than
    // an uninitialised buffer.
    // ⛔ ENG-06: guard the EMPTY path. `capture()` was called unconditionally
    // at frame 1, so with no --screenshot-first the windowed run tried to write
    // a file named "". Also: the flag is now honoured in the HEADLESS path too
    // (see the frame loop in main()), which is where CI can actually use it.
    if (!capturedFirst && frameIndex == 1 && !screenshotFirstPath.empty()) {
      capture(screenshotFirstPath, "screenshot_first");
      capturedFirst = true;
    }

    if (!screenshotPath.empty() && screenshotAfterMs >= 0 && !capturedTimed) {
      auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::steady_clock::now() - start)
                           .count();
      if (elapsedMs >= screenshotAfterMs) {
        capture(screenshotPath, "screenshot");
        capturedTimed = true;
      }
    }

    if (frames > 0 && frameIndex >= frames) break;
  }

  // ⛔ CLEAR THE HANDLER BEFORE ANYTHING IT CAPTURED IS DESTROYED.
  // `surface` is declared FIRST in this function, so it is destroyed LAST —
  // after `fabric`, `host` and `sceneGraph`. The handler holds references to
  // all three, and ~GlfwSurface calls glfwDestroyWindow, which is entitled to
  // dispatch one final damage event. Leaving the handler installed turns
  // shutdown into a use-after-free that would only ever reproduce on exit.
  surface.setRefreshHandler(nullptr);
  // Same argument, same lifetime bug: the mouse handler captures `fabric`.
  // glfwDestroyWindow can dispatch a queued button event, and a click landing
  // after ~FabricHost would dispatch a touch into freed memory.
  surface.setMouseButtonHandler(nullptr);
  // <ScrollView>. ENG-02. Same lifetime argument again: the scroll handler
  // captures `fabric`, and a queued wheel event delivered by glfwDestroyWindow
  // would dispatch into freed memory.
  surface.setScrollHandler(nullptr);
  // ENG-09 hover/cursor. Same lifetime argument: the hover and cursor-leave
  // handlers capture `fabric`, and glfwDestroyWindow can dispatch a queued
  // cursor-position or cursor-enter event, which would then dispatch a pointer
  // event into freed memory.
  surface.setHoverHandler(nullptr);
  surface.setCursorLeaveHandler(nullptr);
  // <TextInput>. ENG-01b. Same lifetime argument: both keyboard handlers
  // capture `fabric`, and glfwDestroyWindow can dispatch a queued char/key
  // event, which would dispatch an edit into freed memory.
  surface.setCharHandler(nullptr);
  surface.setKeyHandler(nullptr);


  // Machine-readable evidence that the modal-loop repaint path executed. A
  // gate asserting only on pixels cannot tell a mid-drag repaint from the
  // single post-release repaint that was already happening.
  printf("rn-impeller: refresh_paints=%d\n", refreshPaints);
  // ⛔ ALWAYS EMITTED, INCLUDING THE ZEROES.
  // touch_downs=0 says the mouse callback never fired — the pre-fix state, and
  // a completely different failure from touch_downs=3 touch_hits=0 (clicks
  // arrived, hit test found nothing). A gate that can only see hits cannot
  // tell those apart, and would call an unregistered callback "no touchables
  // under the cursor".
  printf("rn-impeller: touch_downs=%d touch_hits=%d\n", touchDowns, touchHits);
  // <ScrollView>. ENG-02. Same rule, same reason: scroll_events=0 means the
  // wheel callback never fired (the pre-ENG-02 state), which is a different
  // failure from scroll_events=1 scroll_hits=0 (a wheel arrived over nothing
  // scrollable). A gate that only counts hits calls the first one the second.
  printf("rn-impeller: scroll_events=%d scroll_hits=%d\n", scrollEvents,
         scrollHits);
  // alerts_shown is the host's canonical "JS actually ran" counter. Emitted
  // after the loop so it carries the post-click value; the windowed path had
  // no equivalent of the headless probe's alerts_after_tap until now, so a
  // window gate could see a hit and still not know whether onPress executed.
  printf("rn-impeller: alerts_after_clicks=%zu\n", host.alerts()->count());

  printf("RN_IMPELLER_WINDOW_OK app=%s frames=%d\n", appName.c_str(), frameIndex);
  fflush(stdout);
  return 0;
}
#endif  // RNI_WITH_WINDOW

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
  bool testPointScale = false;
  bool testCaretBlink = false;
  bool testUrlParse = false;
  bool testHttp = false;
  bool windowMode = false;
  int frames = 0;              // 0 = unbounded, run until window closes
  std::string tapSpec;         // "X,Y" in points; empty = no input probe
  // <TextInput>. ENG-01b. Headless editing probe. "--type X,Y:SEQ" focuses the
  // field under (X,Y) POINTS, then replays SEQ one token at a time through the
  // SAME FabricHost::focusTextInputAt / dispatchKey path the GLFW callbacks use,
  // so the whole editing loop (focus -> keystroke -> buffer -> onChange) is
  // gate-provable with no window. SEQ is literal ASCII plus the escapes <BS>
  // (backspace) and <CR> (submit/Enter). Exists for exactly the reason --tap
  // does: the geometry and event wiring are platform-independent and gating them
  // on a working macOS window would leave the input tier unverified on Linux.
  std::string typeSpec;
  // ENG-DRAG (P0). Headless drag probe. "--drag X0,Y0:X1,Y1[:X2,Y2...]" presses
  // at the first point, moves through each subsequent point, releases at the
  // last, all through the SAME beginTouchCapture/dispatchCapturedMove/
  // endTouchCapture path the GLFW mouse+hover callbacks use. Exists for the
  // reason --tap does: the capture logic is platform-independent, and the
  // property it must prove -- every move and the release go to the tag the
  // press captured, even when a waypoint is OFF that control -- is unverifiable
  // by a pixel gate and must not wait on a working macOS window.
  std::string dragSpec;
  int screenshotAfterMs = -1;  // -1 = no timed capture
  std::string screenshotFirst;  // empty = no frame-0 capture
  int resizeAfterFrames = 0;    // 0 = no scripted resize
  int resizeToW = 0;
  int resizeToH = 0;
  // Gate hook for the blocked-frame-loop condition; 0 = off. See the long
  // comment at the stall site in RunWindowed for why --resize-after-frames
  // cannot cover this and this can.
  int stallAfterFrames = 0;
  int stallMs = 300;
  // Windowed synthetic-click hook; 0 = off. Coordinates are SCREEN
  // COORDINATES (what GLFW reports for a cursor), not layout points — the
  // whole point of the hook is to exercise the conversion.
  int clickAfterFrames = 0;
  double clickX = 0.0;
  double clickY = 0.0;
  // <ScrollView>. ENG-02. Screen coordinates and GLFW-convention deltas, same
  // as the click hook: the flag exercises the conversion, so it must be fed
  // the same units GLFW itself reports.
  int scrollAfterFrames = 0;
  double scrollX = 0.0;
  double scrollY = 0.0;
  double scrollDx = 0.0;
  double scrollDy = 0.0;
  // ENG-09 hover/cursor. Screen coordinates, same units as the click/scroll
  // hooks and for the same reason: the hook exercises the screen->points
  // conversion, so it must be fed the coordinates GLFW itself reports. A
  // sequence of points is consumed one-per-frame from hoverAfterFrames, so a
  // single run can walk enter -> within-view -> another-view and, optionally,
  // out of the window.
  int hoverAfterFrames = 0;
  std::vector<std::pair<double, double>> hoverPoints;
  bool hoverLeaveAtEnd = false;
  int width = 400, height = 300;
  // ⛔ WINDOWED DEFAULT IS THE DISPLAY, NOT THESE NUMBERS — SEE GlfwSurface::init.
  // 400x300 is the HEADLESS default and every headless gate depends on it byte
  // for byte, so it stays. On the windowed path an unspecified size means "size
  // to the monitor" (glfwGetMonitorWorkarea, ~70%, centred, floored near
  // 1024x700), not a 400x300 postage stamp: a real app opens at a usable size.
  // These two flags are what let the windowed path tell "user asked for 400"
  // from "user asked for nothing" -- the same defaulted-vs-explicit distinction
  // pointScaleGiven draws for --scale. When false, RunWindowed passes 0 (the
  // auto sentinel) to GlfwSurface::init; --width/--height still override.
  bool widthGiven = false, heightGiven = false;
  // ⛔ --width/--height ARE DEVICE PIXELS, AND --scale IS NOT A ZOOM.
  // The surface is allocated at width x height PIXELS; layout then happens in
  // POINTS = pixels / scale, exactly as a real display works. `--width 800
  // --height 600 --scale 2` is a 400x300-point retina surface, NOT a bigger
  // app — the same fixture renders identical geometry with twice the detail.
  //
  // Default 1.0 keeps every existing gate byte-identical: points == pixels.
  float pointScale = 1.0f;
  // ⛔ "1.0" AND "THE USER ASKED FOR 1.0" MUST BE DISTINGUISHABLE.
  // On the windowed path the display is the source of truth and --scale is an
  // override; without this flag a defaulted 1.0 is indistinguishable from an
  // explicit one, and the derived Retina scale could never be applied without
  // silently ignoring a real `--scale 1`.
  bool pointScaleGiven = false;
  // ENG item 2 — SUPERSAMPLE-RNSVG. N>0 renders each <Svg> root subtree into an
  // N x offscreen and composites it back with a linear downsample, which
  // synthesises the edge-coverage AA Impeller's tessellated stroke path does not
  // emit. Default 4 on darwin (where the tessellated-AA gap was measured), 0
  // (disabled, exact in-place path) elsewhere. --supersample-rnsvg overrides.
#if defined(__APPLE__)
  int supersampleRnsvg = 4;
#else
  int supersampleRnsvg = 0;
#endif
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
    else if (a == "--window") windowMode = true;
    else if (a == "--frames") frames = atoi(next("--frames").c_str());
    // Headless input probe: "--tap X,Y" hit-tests a point in POINTS and
    // dispatches a full down/up pair. Exists so the hit test and the touch
    // dispatch path are testable WITHOUT a window -- the geometry and the
    // emitter wiring are platform-independent, and gating them on a working
    // macOS window would leave the whole input tier unverified on Linux.
    else if (a == "--tap") tapSpec = next("--tap");
    else if (a == "--drag") dragSpec = next("--drag");
    else if (a == "--type") typeSpec = next("--type");
    else if (a == "--screenshot-after") screenshotAfterMs = atoi(next("--screenshot-after").c_str());
    // Frame-0 capture. Pairs with --screenshot/--screenshot-after so ONE run
    // yields two frames to compare; see tools/ci-animate.sh for why a single
    // capture cannot prove the repaint loop is alive.
    else if (a == "--screenshot-first") screenshotFirst = next("--screenshot-first");
    // "--stall-after-frames N:MS" — starve the frame loop for MS milliseconds
    // after frame N while GLFW keeps dispatching events. Reproduces the macOS
    // modal-resize condition (loop blocked, callbacks still firing) on every
    // platform, so the window-refresh repaint is gateable without a mouse.
    else if (a == "--stall-after-frames") {
      std::string spec = next("--stall-after-frames");
      auto colon = spec.find(':');
      if (colon == std::string::npos) {
        fprintf(stderr,
                "rn-impeller: --stall-after-frames wants N:MS (got %s)\n",
                spec.c_str());
        return 2;
      }
      stallAfterFrames = atoi(spec.substr(0, colon).c_str());
      stallMs = atoi(spec.substr(colon + 1).c_str());
      if (stallAfterFrames <= 0 || stallMs <= 0) {
        fprintf(stderr,
                "rn-impeller: --stall-after-frames needs N and MS both > 0 "
                "(got %s)\n",
                spec.c_str());
        return 2;
      }
    }
    // Resize test hook: "--resize-after-frames N:WxH" calls glfwSetWindowSize
    // after frame N. See tools/ci-resize.sh on why a hook rather than a drag.
    else if (a == "--resize-after-frames") {
      std::string spec = next("--resize-after-frames");
      auto colon = spec.find(':');
      auto ex = spec.find('x', colon == std::string::npos ? 0 : colon + 1);
      if (colon == std::string::npos || ex == std::string::npos) {
        fprintf(stderr,
                "rn-impeller: --resize-after-frames wants N:WxH (got %s)\n",
                spec.c_str());
        return 2;
      }
      resizeAfterFrames = atoi(spec.substr(0, colon).c_str());
      resizeToW = atoi(spec.substr(colon + 1, ex - colon - 1).c_str());
      resizeToH = atoi(spec.substr(ex + 1).c_str());
      if (resizeAfterFrames <= 0 || resizeToW <= 0 || resizeToH <= 0) {
        fprintf(stderr,
                "rn-impeller: --resize-after-frames needs N, W and H all > 0 "
                "(got %s)\n",
                spec.c_str());
        return 2;
      }
    }
    // Windowed input test hook: "--click-after-frames N:X,Y" synthesises a
    // left press+release at SCREEN COORDINATES X,Y after frame N. See the
    // hook site in RunWindowed for why this is the WEAKER half of the
    // evidence and what tools/ci-window-input.sh pairs it with.
    else if (a == "--click-after-frames") {
      std::string spec = next("--click-after-frames");
      auto colon = spec.find(':');
      auto comma = spec.find(',', colon == std::string::npos ? 0 : colon + 1);
      if (colon == std::string::npos || comma == std::string::npos) {
        fprintf(stderr,
                "rn-impeller: --click-after-frames wants N:X,Y (got %s)\n",
                spec.c_str());
        return 2;
      }
      clickAfterFrames = atoi(spec.substr(0, colon).c_str());
      clickX = atof(spec.substr(colon + 1, comma - colon - 1).c_str());
      clickY = atof(spec.substr(comma + 1).c_str());
      if (clickAfterFrames <= 0) {
        fprintf(stderr,
                "rn-impeller: --click-after-frames needs N > 0 (got %s)\n",
                spec.c_str());
        return 2;
      }
    }
    // <ScrollView>. ENG-02. Windowed scroll test hook:
    // "--scroll-after-frames N:X,Y,dx,dy" synthesises a wheel scroll at SCREEN
    // COORDINATES X,Y with GLFW-convention deltas dx,dy after frame N.
    //
    // Named to match --resize-after-frames / --click-after-frames /
    // --stall-after-frames rather than a bare --scroll: every hook in this host
    // is anchored to a frame, and an unanchored one would race the first paint.
    // See the hook site in RunWindowed for why it is the WEAKER half.
    else if (a == "--scroll-after-frames") {
      std::string spec = next("--scroll-after-frames");
      auto colon = spec.find(':');
      auto c1 = spec.find(',', colon == std::string::npos ? 0 : colon + 1);
      auto c2 = c1 == std::string::npos ? std::string::npos
                                        : spec.find(',', c1 + 1);
      auto c3 = c2 == std::string::npos ? std::string::npos
                                        : spec.find(',', c2 + 1);
      if (colon == std::string::npos || c1 == std::string::npos ||
          c2 == std::string::npos || c3 == std::string::npos) {
        fprintf(stderr,
                "rn-impeller: --scroll-after-frames wants N:X,Y,dx,dy (got %s)\n",
                spec.c_str());
        return 2;
      }
      scrollAfterFrames = atoi(spec.substr(0, colon).c_str());
      scrollX = atof(spec.substr(colon + 1, c1 - colon - 1).c_str());
      scrollY = atof(spec.substr(c1 + 1, c2 - c1 - 1).c_str());
      scrollDx = atof(spec.substr(c2 + 1, c3 - c2 - 1).c_str());
      scrollDy = atof(spec.substr(c3 + 1).c_str());
      if (scrollAfterFrames <= 0) {
        fprintf(stderr,
                "rn-impeller: --scroll-after-frames needs N > 0 (got %s)\n",
                spec.c_str());
        return 2;
      }
      // A zero delta would produce a scroll event that cannot move anything,
      // and a gate asserting "the offset changed" would fail with a message
      // about scrolling rather than about its own arguments.
      if (scrollDx == 0.0 && scrollDy == 0.0) {
        fprintf(stderr,
                "rn-impeller: --scroll-after-frames needs a non-zero dx or dy "
                "(got %s)\n",
                spec.c_str());
        return 2;
      }
    }
    // ENG-09 hover/cursor. "--hover-after-frames N:X1,Y1;X2,Y2;..." synthesises
    // a cursor MOVE to each SCREEN-COORDINATE point, one per frame starting at
    // frame N. Append ";leave" as a final segment to drive the cursor OUT of
    // the window after the last point. Named to match the other frame-anchored
    // hooks; the sequence is what lets one run show enter, a quiet within-view
    // move, a transition to another view, and a window-exit leave.
    else if (a == "--hover-after-frames") {
      std::string spec = next("--hover-after-frames");
      auto colon = spec.find(':');
      if (colon == std::string::npos) {
        fprintf(stderr,
                "rn-impeller: --hover-after-frames wants N:X1,Y1;X2,Y2;... "
                "(got %s)\n",
                spec.c_str());
        return 2;
      }
      hoverAfterFrames = atoi(spec.substr(0, colon).c_str());
      if (hoverAfterFrames <= 0) {
        fprintf(stderr,
                "rn-impeller: --hover-after-frames needs N > 0 (got %s)\n",
                spec.c_str());
        return 2;
      }
      std::string rest = spec.substr(colon + 1);
      size_t pos = 0;
      while (pos < rest.size()) {
        size_t semi = rest.find(';', pos);
        std::string seg =
            rest.substr(pos, semi == std::string::npos ? std::string::npos
                                                       : semi - pos);
        if (seg == "leave") {
          hoverLeaveAtEnd = true;
        } else if (!seg.empty()) {
          auto comma = seg.find(',');
          if (comma == std::string::npos) {
            fprintf(stderr,
                    "rn-impeller: --hover-after-frames point wants X,Y "
                    "(got %s)\n",
                    seg.c_str());
            return 2;
          }
          double hx = atof(seg.substr(0, comma).c_str());
          double hy = atof(seg.substr(comma + 1).c_str());
          hoverPoints.emplace_back(hx, hy);
        }
        if (semi == std::string::npos) break;
        pos = semi + 1;
      }
      if (hoverPoints.empty()) {
        fprintf(stderr,
                "rn-impeller: --hover-after-frames needs at least one X,Y "
                "point (got %s)\n",
                spec.c_str());
        return 2;
      }
    }
    else if (a == "--log-mutations") logMutations = true;
    else if (a == "--list-modules") listModules = true;
    else if (a == "--test-openurl") testOpenUrl = true;
    else if (a == "--test-pointscale") testPointScale = true;
    else if (a == "--test-caret-blink") testCaretBlink = true;
    else if (a == "--test-urlparse") testUrlParse = true;
    else if (a == "--test-http") testHttp = true;
    else if (a == "--color-scheme") colorScheme = next("--color-scheme");
    else if (a == "--initial-url") initialUrl = next("--initial-url");
    else if (a == "--probe-banner") probeBanner = (next("--probe-banner") != "off");
    else if (a == "--width") { width = atoi(next("--width").c_str()); widthGiven = true; }
    else if (a == "--height") { height = atoi(next("--height").c_str()); heightGiven = true; }
    else if (a == "--scale") {
      pointScale = (float)atof(next("--scale").c_str());
      if (!(pointScale > 0.0f)) {
        fprintf(stderr, "rn-impeller: --scale must be > 0 (got %s)\n",
                argv[i]);
        return 2;
      }
      pointScaleGiven = true;
    }
    else if (a == "--supersample-rnsvg") {
      // N>=0. 0 disables (exact in-place path). 1 is the mutant control (an
      // offscreen round-trip with no supersample). >=2 supersamples. A negative
      // value is rejected rather than silently clamped: it is a caller error,
      // not a mode.
      supersampleRnsvg = atoi(next("--supersample-rnsvg").c_str());
      if (supersampleRnsvg < 0) {
        fprintf(stderr, "rn-impeller: --supersample-rnsvg must be >= 0 (got %s)\n",
                argv[i]);
        return 2;
      }
    }
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
  // Same shape as --test-openurl, and for the same reason: it exercises a
  // decision whose WRONG answer only shows up on hardware CI does not have
  // (a Retina display), on the platform that actually builds today.
  if (testPointScale) return rni::runPointScaleSelfTest();
  // Same shape as --test-pointscale, same reason: the caret blink decision
  // (visible for the first half-period after each keystroke, so typing never
  // lands next to an invisible caret) is a wrong-answer-invisible-on-CI bug --
  // a screenshot might catch an on phase either way. --test-caret-blink
  // exercises the pure predicate directly, on a host with no window and no
  // clock skew.
  if (testCaretBlink) return rni::runCaretBlinkSelfTest();
  // The Networking transport, proven WITHOUT a JS runtime. --test-http stands
  // up a loopback server on an ephemeral port and drives a real GET and a real
  // POST-with-headers through the same performRequest() the TurboModule calls,
  // then asserts the SERVER saw the method, path, headers and body. A test
  // that only checked "the client got 200 back" would pass against a request
  // that dropped every custom header.
  if (testUrlParse) return rni::runUrlSelfTest();
  if (testHttp) return rni::runHttpSelfTest();
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

  if (windowMode) {
#if RNI_WITH_WINDOW
    return RunWindowed(bundlePath, appName, std::move(bundle), 0, bundleSize,
                       colorScheme, initialUrl,
                       widthGiven ? width : 0, heightGiven ? height : 0,
                       pointScale,
                       logMutations, frames, screenshotAfterMs, screenshot,
                       screenshotFirst, pointScaleGiven, resizeAfterFrames,
                       resizeToW, resizeToH, stallAfterFrames, stallMs,
                       clickAfterFrames, clickX, clickY,
                       scrollAfterFrames, scrollX, scrollY, scrollDx, scrollDy,
                       hoverAfterFrames, hoverPoints, hoverLeaveAtEnd,
                       supersampleRnsvg);
#else
    fprintf(stderr,
            "rn-impeller: built without windowed support "
            "(RNI_WITH_WINDOW=OFF). Re-run with --headless.\n");
    return 3;
#endif
  }

  if (!headless) {
    // Neither --headless nor --window was passed. Say so rather than
    // opening nothing and exiting zero.
    fprintf(stderr,
            "rn-impeller: neither --headless nor --window given. "
            "Re-run with one of them.\n");
    return 3;
  }

  PlatformSurface surface;
  std::string error;
  if (!surface.init(width, height, &error)) {
    fprintf(stderr, "rn-impeller: FATAL: %s\n", error.c_str());
    return 1;
  }

  int painted = 0;
  size_t nodeCount = 0;
  {
    rni::SceneGraph sceneGraph(surface.typography());
    // ENG item 2 — same wiring as the primary headless path above.
    sceneGraph.setRenderContext(surface.context());
    sceneGraph.setSupersample(supersampleRnsvg);
    // ENG item 2b — root supersample offscreen size, device pixels.
    sceneGraph.setSurfaceSize(width, height);
    rni::ReactHost host;
    host.setKnownComponents(rni::FabricHost::knownComponentNames());
    // ⛔ JS MUST SEE THE SAME SCALE FABRIC LAYS OUT WITH.
    // Dimensions/PixelRatio read this. RN code branches on PixelRatio.get()
    // for asset selection (@2x/@3x) and hairline widths, so reporting 1 while
    // laying out at 2 gives an app that is internally inconsistent: correct
    // geometry, wrong assets. window/screen are POINTS, which is what
    // Dimensions.get('window') means on every other RN platform.
    host.displayMetrics()->set((float)width / pointScale,
                               (float)height / pointScale, pointScale);
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

    fabric.startSurface(appName, 1, (float)width, (float)height, pointScale);
    // React renders, Fabric commits, the delegate applies mutations — all on
    // the JS thread. Idle means that whole chain has drained.
    host.waitForJsIdle(10000);

    // ⛔ AN IDLE JS THREAD DOES NOT MEAN THE NETWORK FINISHED.
    // A request runs on a native worker; while it is on the wire there is no
    // pending JS task, so waitForJsIdle returns true immediately and a
    // headless capture screenshots before any response has landed. Measured on
    // the first two P10 runs: the Networking module resolved (swatch green)
    // and every request swatch was red, with NO JS error — a working transport
    // presenting exactly like a dead one.
    //
    // So: drain the network, THEN let the JS that its responses scheduled
    // (setState -> render -> commit -> mutations) drain in turn. Both waits are
    // bounded; a stuck socket must fail the gate, not hang CI forever.
    if (auto net = host.network()) {
      auto netDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
      while (net->inFlight.load() > 0 &&
             std::chrono::steady_clock::now() < netDeadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
      // The native-side side-effect counter, same role alerts_shown plays for
      // AlertManager: a pixel proves JS received a response, this proves a
      // request actually crossed into native and completed.
      printf("rn-impeller: net_requests_completed=%d net_in_flight=%d\n",
             net->completed.load(), net->inFlight.load());
      host.waitForJsIdle(10000);
    }

    // Counted AFTER the network settle: nodes mounted by a response handler
    // do not exist yet at the point the old count was taken.
    nodeCount = sceneGraph.nodeCount();
    printf("rn-impeller: scene_nodes=%zu\n", nodeCount);
    printf("rn-impeller: supersample_rnsvg=%d\n", sceneGraph.supersample());
    // Side effects the modules recorded, so a gate can assert that JS actually
    // REACHED native rather than merely that the app rendered something.
    printf("rn-impeller: alerts_shown=%zu\n", host.alerts()->count());
    // Always emitted, not gated behind --log-mutations: a gate needs the frames
    // to prove LAYOUT, and painted pixels alone cannot (a 0x0-measured <Text>
    // still paints its glyphs).
    fputs(sceneGraph.frameReport().c_str(), stdout);
    // Input probe. Runs AFTER the tree is mounted and laid out -- a hit test
    // against an empty scene graph would report "no hit" for reasons that have
    // nothing to do with the hit test.
    if (!tapSpec.empty()) {
      float tx = 0, ty = 0;
      if (std::sscanf(tapSpec.c_str(), "%f,%f", &tx, &ty) == 2) {
        int hit = fabric.dispatchTouch(rni::FabricHost::TouchPhase::Down, tx, ty);
        printf("rn-impeller: tap_hit=%d at=%.1f,%.1f\n", hit, tx, ty);
        if (hit) {
          fabric.dispatchTouch(rni::FabricHost::TouchPhase::Up, tx, ty);
        }
        fflush(stdout);
        // Let the scheduled work reach the JS thread: dispatchTouch is
        // asynchronous by design, so returning immediately would end the
        // process before any handler ran and make a WORKING dispatch look dead.
        host.waitForJsIdle(5000);
        // ⛔ RE-EMIT THE COUNTER *AFTER* THE TAP.
        // `alerts_shown` above is printed before this probe runs, so it can
        // only ever read 0 here no matter how well dispatch works. This line
        // is the post-tap value and the only one an input gate may assert on.
        printf("rn-impeller: alerts_after_tap=%zu\n", host.alerts()->count());
        fflush(stdout);
      } else {
        fprintf(stderr, "rn-impeller: FATAL: --tap wants X,Y (got '%s')\n",
                tapSpec.c_str());
        return 1;
      }
    }

    // ENG-DRAG (P0). Headless drag probe. Press at the first point, move through
    // the rest, release at the last -- through the SAME capture path the window
    // uses. Emits the tag each phase reached so a gate can assert the invariant
    // a pixel check cannot: every move and the release stay on the pressed tag,
    // even a waypoint OFF that control. drag_move_tag != drag_down_tag is the
    // exact bug (a re-hit-testing move retargets); drag_move_tag=0 with a
    // non-zero down is the other (no capture -- the off-control move hit
    // nothing). Both are separable from a working drag here.
    if (!dragSpec.empty()) {
      // Parse "X0,Y0:X1,Y1:..." into points. At least two are required: a press
      // and one move/release. sscanf per colon-separated token.
      std::vector<std::pair<float, float>> pts;
      size_t start = 0;
      bool parseOk = true;
      while (start <= dragSpec.size()) {
        size_t colon = dragSpec.find(':', start);
        std::string tok = dragSpec.substr(
            start, colon == std::string::npos ? std::string::npos : colon - start);
        float px = 0, py = 0;
        if (std::sscanf(tok.c_str(), "%f,%f", &px, &py) != 2) {
          parseOk = false;
          break;
        }
        pts.emplace_back(px, py);
        if (colon == std::string::npos) break;
        start = colon + 1;
      }
      if (!parseOk || pts.size() < 2) {
        fprintf(stderr,
                "rn-impeller: FATAL: --drag wants X0,Y0:X1,Y1[:...] with >=2 "
                "points (got '%s')\n",
                dragSpec.c_str());
        return 1;
      }
      // Press captures the first point's tag.
      int downTag = fabric.beginTouchCapture(pts.front().first, pts.front().second);
      printf("rn-impeller: drag_down_tag=%d at=%.1f,%.1f\n", downTag,
             pts.front().first, pts.front().second);
      // Every intermediate point is a held move; the LAST point is the release.
      // Report the tag each move reached: it MUST equal downTag for the whole
      // drag, including a waypoint outside the control's bounds.
      int lastMoveTag = downTag;
      for (size_t i = 1; i + 1 < pts.size(); ++i) {
        int mt = fabric.dispatchCapturedMove(pts[i].first, pts[i].second);
        lastMoveTag = mt;
        printf("rn-impeller: drag_move_tag=%d at=%.1f,%.1f\n", mt, pts[i].first,
               pts[i].second);
      }
      // For a 2-point drag (press + release with no intermediate move), emit a
      // move at the release point too, so the "move stays on the down tag"
      // assertion always has a line to read -- otherwise a 2-point drag would
      // leave drag_move_tag absent and the gate could not tell capture from a
      // plain tap. This move is at the release point, which is the off-control
      // location the gate places to catch a re-hit-test.
      if (pts.size() == 2) {
        int mt = fabric.dispatchCapturedMove(pts.back().first, pts.back().second);
        lastMoveTag = mt;
        printf("rn-impeller: drag_move_tag=%d at=%.1f,%.1f\n", mt,
               pts.back().first, pts.back().second);
      }
      int upTag = fabric.endTouchCapture(pts.back().first, pts.back().second);
      printf("rn-impeller: drag_up_tag=%d at=%.1f,%.1f\n", upTag,
             pts.back().first, pts.back().second);
      // After release the capture MUST be clear: a move now is a hover, not a
      // drag. captured=0 here proves endTouchCapture reset the state -- a stuck
      // capture would silently swallow every later click as a drag move.
      printf("rn-impeller: drag_captured_after=%d\n",
             fabric.isTouchCaptured() ? 1 : 0);
      fflush(stdout);
      host.waitForJsIdle(5000);
      // Re-emit alerts after the drag for the same reason --tap does: the
      // pre-probe alerts_shown is always 0. A press+release on a Pressable
      // fires onPress, so a captured drag that lands its Up on the down tag
      // still resolves the press.
      printf("rn-impeller: alerts_after_drag=%zu\n", host.alerts()->count());
      (void)lastMoveTag;
      fflush(stdout);
    }

    // <TextInput>. ENG-01b. Headless editing probe. Focus the field, replay the
    // keystroke sequence, drain JS after each, then report what the SceneGraph
    // holds and what the emitter reached. This drives the SAME
    // FabricHost::focusTextInputAt / dispatchKey the GLFW callbacks call, so a
    // green --type run proves the whole loop without a window.
    if (!typeSpec.empty()) {
      auto colon = typeSpec.find(':');
      float fx = 0, fy = 0;
      if (colon == std::string::npos ||
          std::sscanf(typeSpec.substr(0, colon).c_str(), "%f,%f", &fx, &fy) != 2) {
        fprintf(stderr, "rn-impeller: FATAL: --type wants X,Y:SEQ (got '%s')\n",
                typeSpec.c_str());
        return 1;
      }
      // ⛔ SETTLE THE MOUNT BEFORE THE FIRST HIT TEST.
      // startSurface + waitForJsIdle above drains the JS thread, but under load
      // (a gate packs+installs+bundles immediately before launch) the delegate
      // can apply the mount transaction that POSITIONS this field a beat after
      // JS goes idle. Focusing then finds no field and returns 0 -- a focus=0
      // flake measured in ci-textedit.sh, indistinguishable from an
      // unregistered field. A real window never has this problem: a human
      // clicks long after layout. So poll for a REAL TextInput at the target
      // point (isTextInputAt, not a bare hitTest -- the full-surface background
      // <View> hits everywhere and resolves the instant the root mounts, long
      // before the field), pumping JS idle each turn, until it appears or a
      // bounded deadline expires. Same drain-then-verify discipline the network
      // wait uses; a tree that never lays out must fail the gate, not hang.
      auto mountStart = std::chrono::steady_clock::now();
      auto mountDeadline = mountStart + std::chrono::seconds(10);
      while (!fabric.isTextInputAt(fx, fy) &&
             std::chrono::steady_clock::now() < mountDeadline) {
        host.waitForJsIdle(200);
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      }
      // Report the settle so a slow mount (field resolved late) and a
      // never-mount (deadline hit, still no field) are DISTINGUISHABLE in the
      // log -- the gate's focus=0 message otherwise blames hit-testing for a
      // timeout. field=1 means a TextInput is under the point and focus WILL
      // succeed; field=0 after ~10000ms means the field never laid out.
      auto settleMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::steady_clock::now() - mountStart)
                          .count();
      printf("rn-impeller: type_mount_settle_ms=%lld field=%d\n",
             (long long)settleMs, (int)fabric.isTextInputAt(fx, fy));
      fflush(stdout);
      int focused = fabric.focusTextInputAt(fx, fy);
      printf("rn-impeller: type_focus=%d at=%.1f,%.1f\n", focused, fx, fy);
      host.waitForJsIdle(5000);
      const std::string seq = typeSpec.substr(colon + 1);
      for (size_t i = 0; i < seq.size();) {
        if (seq.compare(i, 4, "<BS>") == 0) {
          fabric.dispatchKey(rni::FabricHost::KeyAction::Backspace, 0);
          i += 4;
        } else if (seq.compare(i, 4, "<CR>") == 0) {
          fabric.dispatchKey(rni::FabricHost::KeyAction::Submit, 0);
          i += 4;
        } else {
          fabric.dispatchKey(rni::FabricHost::KeyAction::InsertChar,
                             (unsigned char)seq[i]);
          i += 1;
        }
        host.waitForJsIdle(5000);
      }
      // The engine's own view of the field: buffer, length, caret. This is the
      // painted truth. A gate asserts len/v here AND checks the JS-side label
      // (the fixture renders `len=${v.length} v=${v}`) matches, so buffer and
      // JS state cannot silently disagree.
      std::string v = sceneGraph.textInputValueFor(focused);
      size_t caret = sceneGraph.textInputCaretFor(focused);
      printf("rn-impeller: textinput_value tag=%d len=%zu caret=%zu v=%s\n",
             focused, v.size(), caret, v.c_str());
      // The JS-side truth: every Paragraph's painted text. The fixture's
      // controlled label renders `len=N v=...`, so this line proves onChangeText
      // actually ran in JS and re-rendered -- not merely that the native buffer
      // changed. A gate diffs this against textinput_value above.
      fputs(sceneGraph.paragraphTextReport().c_str(), stdout);
      fflush(stdout);
    }

    if (logMutations) {
      printf("rn-impeller: scene=%s\n", sceneGraph.describe().c_str());
    }
    fflush(stdout);

    // ⛔ ENG-06: THE HEADLESS ANIMATION ARM.
    // Until now headless was strictly single-shot: evaluate, settle, paint
    // once, read pixels, exit. That is why --frames and --screenshot-first
    // were accepted and did nothing here -- the only code that honoured them
    // lived in RunWindowed(), which needs a GLFW window and therefore cannot
    // run on CI. An animation cannot be proven by one frame no matter how good
    // that frame is, so headless needs a real stepped loop.
    //
    // The clock is the LOOP COUNTER, not wall time: pumping the NativeAnimated
    // engine once per iteration means `--frames N` advances the animation by
    // exactly N steps on a fast machine and a slow one alike.
    if (frames > 0) {
      for (int frameIndex = 1; frameIndex <= frames; ++frameIndex) {
        // One NativeAnimated step. Posts to the JS thread, so drain it before
        // painting or the capture races the value update it is meant to show.
        host.pumpNativeAnimated();
        host.waitForJsIdle(5000);

        ImpellerDisplayListBuilder fb = ImpellerDisplayListBuilderNew(nullptr);
        sceneGraph.paint(fb, pointScale);
        ImpellerDisplayList fdl =
            ImpellerDisplayListBuilderCreateDisplayListNew(fb);
        if (fdl != nullptr) {
          surface.drawDisplayList(fdl);
          ImpellerDisplayListRelease(fdl);
        }
        ImpellerDisplayListBuilderRelease(fb);

        // Frame-0 capture, taken AFTER the first real paint so it is a
        // rendered frame and not an uninitialised buffer. This plus the final
        // --screenshot is what lets one run be diffed against itself, which is
        // the only way to tell a live animation from a static engine redrawing
        // identical pixels forever.
        if (frameIndex == 1 && !screenshotFirst.empty()) {
          std::vector<rni::Px> fpx;
          if (surface.readPixels(&fpx) &&
              PlatformSurface::writePpm(screenshotFirst, fpx, width, height)) {
            printf("rn-impeller: screenshot_first=%s\n",
                   screenshotFirst.c_str());
          } else {
            fprintf(stderr,
                    "rn-impeller: WARN: cannot write screenshot-first %s\n",
                    screenshotFirst.c_str());
          }
        }
      }
      // The half of the ENG-06 proof that lives on THIS side of the boundary.
      // RN's Animated silently falls back to its JS driver when the native
      // module is missing, and both drivers move the same pixels -- so a
      // pixel diff alone would stay green with the entire C++ animation engine
      // removed. A gate must assert this is non-zero too.
      printf("rn-impeller: nativeanimated_ticks=%lu\n",
             host.nativeAnimatedTicks());
      // ⛔ THE OTHER HALF OF THE PROOF, AND THE ONE THAT WAS MISSING.
      //
      // nativeanimated_ticks says the PUMP ran. It says nothing about whether
      // anything downstream consumed the props, and for one full commit it did
      // not: ticks read 60/60 while every animated pixel stayed frozen, because
      // schedulerShouldSynchronouslyUpdateViewOnUIThread was an empty stub and
      // the computed opacity was discarded. A gate on ticks alone is green
      // through that entire defect.
      //
      // This counts props APPLIED to real nodes. ticks>0 with updates==0 is the
      // exact signature of that bug and is now distinguishable from both "no
      // animation ran" and "the animation worked".
      printf("rn-impeller: directprop_updates=%lu\n",
             sceneGraph.directPropUpdates());
      fflush(stdout);
    }

    ImpellerDisplayListBuilder builder = ImpellerDisplayListBuilderNew(nullptr);
    painted = sceneGraph.paint(builder, pointScale);
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
    if (PlatformSurface::writePpm(screenshot, px, width, height)) {
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
