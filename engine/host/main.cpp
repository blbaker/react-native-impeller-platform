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
#include <thread>
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
#include "scenegraph/CursorKinds.h"
#include "impeller.h"
#include "runtime/FeatureFlags.h"
#if !defined(_WIN32)
#include <unistd.h>
#else
#include <process.h>
#endif
#include "host/FrameTimings.h"
#include "host/FrameScheduler.h"
#include "host/AnimRowProbe.h"
#include "base/Trace.h"
#include "base/DevToolsFrames.h"
#include "base/SanitizerHooks.h"
#if RNI_FUZZ
#include "fuzz/Fuzz.h"
#endif
#include "base/GlValidation.h"
#include "base/ContextFlags.h"
#include "fabric/ImageStore.h"
#include "host/MemoryPressure.h"
#include "host/OsAppearance.h"
#include "modules/NetworkingModule.h"
#include "runtime/ReactHost.h"
#include "scenegraph/SceneGraph.h"
#include "text/FontRegistry.h"
#include "text/TypographyContexts.h"

// ENG-22: --font-dir values, registered with each surface's typography context
// right after init and BEFORE anything measures (see text/FontRegistry.h).
static std::vector<std::string> gFontDirs;

// --title: windowed-mode window title (title bar + macOS Window menu). Empty =
// GlfwSurface's default, "React Native (Impeller)".
static std::string gWindowTitle;

// Process-start clock for the first_present_ms line. Static init runs before
// main(), so this is as close to "launch" as the process can see.
static const auto gProcessStart = std::chrono::steady_clock::now();
static int SinceLaunchMs() {
  return (int)std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now() - gProcessStart)
      .count();
}

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
          "                     default 4 on darwin + Windows, 0 (off) elsewhere\n"
          "                   [--image-cache-mb N]  decoded-image LRU budget in MB;\n"
          "                     default 100 (Flutter ImageCache). Env: RNI_IMAGE_CACHE_MB,\n"
          "                     RNI_IMAGE_CACHE_FLOOR_MB (low-memory purge floor, default 0) (FP-33)\n"
          "                   [--sdf-aa on|off]  analytic SDF AA for circles, ovals,\n"
          "                     rects, rounded rects (Impeller Flags::use_sdfs, SDK\n"
          "                     patch 0003). Default off (FP-22)\n"
          "                   [--initial-url URL]\n"
          "                   [--window] [--frames N] [--screenshot-after MS]\n"
          "                   [--frame-timings-out <file.json>]  one record per\n"
          "                     presented frame (FP-01)\n"
          "                   [--trace-out <file.json>]  Chrome/Perfetto trace of\n"
          "                     spans + counters (FP-02)\n"
          "                   [--trace-bench N]  print the off-mode cost of one span\n"
          "                     and exit\n"          "                   [--title <string>]  (windowed) window title, also\n"
          "                     the macOS Window menu entry. Default\n"
          "                     \"React Native (Impeller)\".\n"
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
  // ENG-09 — wire the world raster store so --list-modules boots identically.
  sceneGraph.setWorldRasterStore(host.worldRasterStore());
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

  // globalThis.expo.modules (ExpoHost.h), listed as expo_module= lines so
  // the ^module= parsers in ci-p4/ci-p10 do not read them as TurboModules.
  std::string expoNames;
  for (const auto& [n, _] : host.expoModules()->defs()) {
    if (!expoNames.empty()) expoNames += ",";
    expoNames += "'" + n + "'";
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
      "  var expoNames = [" + expoNames + "];\n"
      "  for (var j = 0; j < expoNames.length; j++) {\n"
      "    var en = expoNames[j];\n"
      "    var em = g.expo && g.expo.modules ? g.expo.modules[en] : null;\n"
      "    if (em == null) { console.log('expo_module=' + en + ' methods=<UNREACHABLE FROM JS>'); continue; }\n"
      "    var ek = Object.keys(em).sort();\n"
      "    console.log('expo_module=' + en + ' methods=' + ek.join(','));\n"
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

// desktop-input-gap P0 item 1. Windowed keyboard test hook payload, shared
// between main()'s --key-after-frames parser (built unconditionally) and
// RunWindowed's consumer loop (RNI_WITH_WINDOW only). Defined OUTSIDE the
// RNI_WITH_WINDOW guard below so main() can reference it on every platform,
// including a headless-only build where RunWindowed does not exist at all.
struct KeySpec {
  std::string key;
  int phase = 0;  // 0=down 1=repeat 2=up
  bool shift = false, ctrl = false, alt = false, meta = false,
       capsLock = false;
};

// desktop-input-gap item 2a. One synthetic CHARACTER (decoded Unicode
// codepoint), consumed one-per-frame the same way KeySpec is -- see
// --char-after-frames's flag-parser comment for the wire format. File-scope
// for the same reason KeySpec is: RunWindowed (RNI_WITH_WINDOW only) and
// main()'s flag parser (built unconditionally) both need the type.
struct CharSpec {
  unsigned int codepoint = 0;
};

// item 4b. One synthetic mouse event: op 0 press, 1 release, 2 move; x/y in
// SCREEN coords; shift held for a press.
struct MouseSpec {
  int op = 0;
  double x = 0.0, y = 0.0;
  bool shift = false;
  // item 6: W3C button (0 left .. 4 forward) and full modifiers. When
  // `button` is set (>= 0), the event goes through synthesiseMouseButton.
  int button = -1;
  bool ctrl = false, alt = false, meta = false;
};

// ENG-18. One --type token. The headless probe and the windowed hook both
// read the SAME parsed list, so a spec means the same thing in both modes.
//   plain text   one character (UTF-8 decoded to a codepoint)
//   <BS>         Backspace       <CR>    Enter        <S-CR>  Shift+Enter
//   <SA>         select all      <COPY>  copy         <CUT>   cut
struct TypeToken {
  enum Kind { Char, Backspace, Enter, ShiftEnter, SelectAll, Copy, Cut } kind;
  unsigned int codepoint = 0;
};

static std::vector<TypeToken> ParseTypeSeq(const std::string& seq) {
  std::vector<TypeToken> out;
  static const struct { const char* tag; TypeToken::Kind kind; } kTags[] = {
      {"<S-CR>", TypeToken::ShiftEnter}, {"<BS>", TypeToken::Backspace},
      {"<CR>", TypeToken::Enter},        {"<SA>", TypeToken::SelectAll},
      {"<COPY>", TypeToken::Copy},       {"<CUT>", TypeToken::Cut},
  };
  for (size_t i = 0; i < seq.size();) {
    bool tagged = false;
    for (const auto& t : kTags) {
      const size_t n = std::strlen(t.tag);
      if (seq.compare(i, n, t.tag) == 0) {
        out.push_back({t.kind, 0});
        i += n;
        tagged = true;
        break;
      }
    }
    if (tagged) continue;
    // UTF-8 decode one codepoint (ASCII is one byte, unchanged from before).
    const unsigned char c = (unsigned char)seq[i];
    unsigned int cp = c;
    size_t len = 1;
    if (c >= 0xF0) {
      cp = c & 0x07; len = 4;
    } else if (c >= 0xE0) {
      cp = c & 0x0F; len = 3;
    } else if (c >= 0xC0) {
      cp = c & 0x1F; len = 2;
    }
    if (i + len > seq.size()) len = 1, cp = c;
    for (size_t k = 1; k < len; ++k) cp = (cp << 6) | ((unsigned char)seq[i + k] & 0x3F);
    out.push_back({TypeToken::Char, cp});
    i += len;
  }
  return out;
}

// ENG-24: a multiline value prints on ONE log line ('\n' -> "\\n").
static std::string EscapeNewlines(const std::string& v) {
  std::string out;
  for (char ch : v) {
    if (ch == '\n') out += "\\n";
    else out += ch;
  }
  return out;
}

// ENG-18: the windowed --type spec, set by main() before RunWindowed. File
// scope (like gFontDirs) so RunWindowed's long positional signature does not
// grow again. Empty = no windowed typing.
static std::string gWindowedTypeSpec;
// FP-11: --vsync auto|swap|software|off and --vsync-log (windowed only).
static rni::FrameScheduler::Source gVsyncSource = rni::FrameScheduler::Source::kAuto;
static bool gVsyncSet = false;
static bool gVsyncLog = false;

// FP-01: --frame-timings-out <file.json>. File scope for the same reason.
static std::string gFrameTimingsOut;

// FP-02: --trace-out <file.json>. Written once, at the end of the run.
static std::string gTraceOut;

static void FinishTrace() {
  const uint64_t events = rni::trace::EventCount();
  if (gTraceOut.empty()) {
    printf("rn-impeller: trace enabled=%d events=%llu\n", rni::trace::Enabled() ? 1 : 0,
           (unsigned long long)events);
    return;
  }
  const bool ok = rni::trace::Stop();
  printf("rn-impeller: trace enabled=0 events=%llu written=%d out=%s\n",
         (unsigned long long)events, ok ? 1 : 0, gTraceOut.c_str());
}

// FP-02: cost of a span while tracing is OFF, measured in-process through the
// same macro the engine uses, against an empty loop with the same barrier.
static int RunTraceBench(long iterations) {
  using Clock = std::chrono::steady_clock;
  auto timeLoop = [&](bool withSpan) {
    const auto t0 = Clock::now();
    for (long i = 0; i < iterations; ++i) {
      if (withSpan) {
        TRACE_EVENT0("bench", "span");
        asm volatile("" ::: "memory");
      } else {
        asm volatile("" ::: "memory");
      }
    }
    return std::chrono::duration<double, std::nano>(Clock::now() - t0).count();
  };
  timeLoop(true);  // warm up
  double best = 1e30;
  for (int rep = 0; rep < 5; ++rep) {
    const double span = timeLoop(true), base = timeLoop(false);
    best = std::min(best, std::max(0.0, span - base) / (double)iterations);
  }
  printf("rn-impeller: trace_bench enabled=%d ns_per_span=%.3f\n", rni::trace::Enabled() ? 1 : 0, best);
  return 0;
}

// Exit report of both loops: the summary line always, the JSON when asked.
static void FinishFrameTimings(const rni::FrameTimings& timings) {
  timings.PrintSummary(stdout);
  if (gFrameTimingsOut.empty()) return;
  if (timings.WriteJson(gFrameTimingsOut)) {
    printf("rn-impeller: frame_timings_out=%s\n", gFrameTimingsOut.c_str());
  } else {
    fprintf(stderr, "rn-impeller: WARN: cannot write frame timings %s\n",
            gFrameTimingsOut.c_str());
  }
  fflush(stdout);
}

static bool gFollowOsAppearance = false;  // SC-23 (set in headless builds too)
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
// parity item 14: defined below main()'s argv capture.
[[noreturn]] static void ReexecForReload(const std::string& reason);

int RunWindowed(const std::string& sourceUrl, const std::string& appName,
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
                bool hoverLeaveAtEnd,
                int keyAfterFrames, const std::vector<KeySpec>& keySequence,
                int charAfterFrames, const std::vector<CharSpec>& charSequence,
                int mouseAfterFrames, const std::vector<MouseSpec>& mouseSequence,
                int supersampleRnsvg,
                bool idleSkip, double idleRunSec, int idleBudgetMs,
                bool idleLog, int idleMutant, int idleOffthreadAfter) {
  (void)nodeReportOnly;
  (void)bundleSize;
  rni::GlfwSurface surface;
  std::string error;
  surface.setTitle(gWindowTitle);  // before init: glfwCreateWindow takes it
  std::printf("rn-impeller: window_title=%s\n", surface.title().c_str());
  std::fflush(stdout);
  if (!surface.init(width, height, &error)) {
    fprintf(stderr, "rn-impeller: FATAL: %s\n", error.c_str());
    return 1;
  }
  // ENG-22: app fonts before the first measure (FabricHost is built below).
  rni::RegisterFontDirs(surface.typography(), rni::FontDirsFrom(gFontDirs));

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
  // Android the offscreen path is compiled out, so these are inert there.
  sceneGraph.setRenderContext(surface.context());
  sceneGraph.setSupersample(supersampleRnsvg);
  // ENG item 2b — the root supersample offscreen is sized N x this. Device
  // pixels (surface.width()/height()), re-set on resize below.
  sceneGraph.setSurfaceSize(surface.width(), surface.height());
  // The cursor conversion divides by this. Set from the SAME derived value the
  // layout uses, and re-set on every resize below, so a click can never be
  // converted with a scale the painter is no longer using.
  surface.setPointScale(pointScale);
  // parity item 24: a Metro-served bundle is debuggable (React Native DevTools).
  rni::ReactHost host(/*withInspector*/ sourceUrl.rfind("http://", 0) == 0);
  host.setKnownComponents(rni::FabricHost::knownComponentNames());
  // ENG-09 — the <world> painter reads pixel buffers the WorldRaster
  // TurboModule writes; give the SceneGraph the same store the host owns.
  sceneGraph.setWorldRasterStore(host.worldRasterStore());
  host.displayMetrics()->set((float)pxWidth / pointScale,
                             (float)pxHeight / pointScale, pointScale);
  host.appearance()->set(colorScheme);
  *host.initialUrl() = initialUrl;
  // SC-23: report OS theme changes to JS. Declared after `host`, so it is
  // joined before the host (and its device-event sink) is destroyed.
  std::unique_ptr<rni::OsAppearanceWatcher> osWatcher;
  if (gFollowOsAppearance) {
    auto* hostPtr = &host;
    osWatcher = std::make_unique<rni::OsAppearanceWatcher>(
        colorScheme, true,
        [hostPtr](const std::string& scheme) {
          if (!hostPtr->appearance()->setSystem(scheme)) return;
          printf("rn-impeller: appearance_changed scheme=%s source=os\n", scheme.c_str());
          fflush(stdout);
          hostPtr->deviceEvents()->emit(
              "appearanceChanged", folly::dynamic::object("colorScheme", scheme));
        });
  }

  rni::FabricHost fabric(host.instance(), &sceneGraph, surface.typography(),
                         logMutations, host.displayMetrics());

  // item 5. A real GLFW window exists here, so wire the ClipboardBridge's
  // "system backend" pair to the surface's glfwGetClipboardString/
  // glfwSetClipboardString wrappers, and give it the wake callback so a
  // request queued while the loop is parked in --idle-skip's
  // glfwWaitEventsTimeout wakes it promptly. See ClipboardBridge.h.
  auto clipboard = host.clipboard();
  clipboard->setSystemBackend(
      [&surface]() { return surface.getClipboardString(); },
      [&surface](const std::string& s) { surface.setClipboardString(s); });
  clipboard->setWake([&surface]() { surface.postEmptyEvent(); });
  // item 7: windowed view commands run on this (main) thread.
  fabric.enableMainQueue([&surface]() { surface.postEmptyEvent(); });
  // The TextInput Copy/Cut/Paste shortcuts run ON THE MAIN THREAD (the GLFW
  // key callback), so they read/write the clipboard DIRECTLY through the
  // bridge's synchronous accessors rather than through the queue -- see
  // FabricHost::setClipboardAccess's header comment.
  fabric.setClipboardAccess(
      [clipboard]() { return clipboard->getSystemNow(); },
      [clipboard](const std::string& s) { clipboard->setSystemNow(s); });

  // parity item 14: DevSettings.reload() re-execs (see ReexecForReload).
  // Called on the JS thread; the re-exec replaces the whole process.
  host.setReloadHook([](const std::string& reason) { ReexecForReload(reason); });
  host.runScript(std::move(bundle), sourceUrl);
  // ⛔ WINDOWED BOOT DRAINS THE JS QUEUE, IT DOES NOT WAIT FOR JS IDLE.
  // waitForJsIdle counts every pending one-shot timer, and RN core's
  // requestAnimationFrame is setTimeout(0). An app that starts a launch
  // animation in its first effect is never "idle" until the animation ends,
  // so the frame loop below did not start, and nothing was presented, until
  // then: on the Mac the first frame was HostApp's Home screen ~1.5 s after JS
  // started and the boot mark was never seen (D-156). The drain still waits
  // for the bundle, runApplication and the first commit, so frame 0 is the
  // app's first committed tree, not a blank window. The headless path keeps
  // waitForJsIdle: its frames are deterministic snapshots, not a live clock.
  const int bootWaitStart = SinceLaunchMs();
  const bool bundleDrained = host.waitForJsQueueDrained(10000);
  // parity item 14: a bundle from Metro starts HMR (Fast Refresh).
  host.devServerSetup(sourceUrl);
  host.connectInspector(sourceUrl, appName);  // parity item 24
  // startSurface takes DEVICE PIXELS and divides by pointScale itself
  // (FabricHost.cpp:279) — so it gets the framebuffer size, not the request.
  fabric.startSurface(appName, 1, (float)pxWidth, (float)pxHeight, pointScale);
  const bool surfaceDrained = host.waitForJsQueueDrained(10000);
  printf("rn-impeller: boot_wait_ms=%d drained=%d/%d\n",
         SinceLaunchMs() - bootWaitStart, bundleDrained ? 1 : 0,
         surfaceDrained ? 1 : 0);

  printf("rn-impeller: scene_nodes=%zu\n", sceneGraph.nodeCount());
  printf("rn-impeller: supersample_rnsvg=%d\n", sceneGraph.supersample());
  fflush(stdout);

  // Incremented inside paintFrame at the present, so it counts FRAMES THAT
  // REACHED THE SCREEN. Declared before paintFrame because that lambda
  // captures it.
  int paintsTotal = 0;

  // ⛔ WINDOWED CAPTURE READS BACK BEFORE THE PRESENT, NEVER AFTER IT.
  // eglSwapBuffers hands the frame to the compositor and leaves the back
  // buffer UNDEFINED (EGL_BUFFER_DESTROYED is the default swap behaviour). On
  // ANGLE-Metal the next glReadPixels on fbo 0 gets a FRESH, CLEARED drawable:
  // darwin windowed --screenshot / --screenshot-first came back as 3,072,000
  // zero bytes at 1280x800 on every frame (ENG-10, 2026-09-26), while Mesa/X11
  // happened to keep the old back buffer, so linux gates never saw it. The
  // loop arms grabArmed for the frame it wants; paintFrame reads the pixels
  // between drawDisplayList (which glFinish()es) and present().
  bool grabArmed = false;
  bool grabOk = false;
  std::vector<rni::Px> grabPx;

  // FP-01: one recorder per frame, committed at the present (model:
  // flutter/flow/frame_timings.h). Idle-skipped loop frames are discarded.
  rni::FrameTimings frameTimings;

  // FP-11: frame requests + vsync (model: flutter/shell/common/animator.cc and
  // vsync_waiter_fallback.cc). Idle-skip M3 keeps the request but drops the
  // wake, so a sleeping loop only notices it at the end of its budget.
  rni::FrameScheduler scheduler(
      rni::FrameScheduler::Options{gVsyncSource, 60.0, gVsyncLog},
      [&surface](double s) { surface.waitEvents(s); },
      (idleSkip && idleMutant == 3)
          ? rni::FrameScheduler::WakeFn()
          : rni::FrameScheduler::WakeFn([&surface]() { surface.postEmptyEvent(); }),
      [&surface](int interval) { surface.setSwapInterval(interval); });

  auto paintFrame = [&](std::unique_ptr<rni::FrameTimingsRecorder> frame) -> int {
    // ⛔ THE PAINT-IN-FLIGHT SCOPE GOES HERE, AT THE ONE SHARED BODY.
    // Both the frame loop and the window-refresh callback paint through this
    // lambda, so scoping the guard here is what makes it cover every paint
    // rather than only the callback's. surface.present() below is the call
    // that can re-enter: eglSwapBuffers -> CAMetalLayer update ->
    // -[NSView updateLayer] -> _glfwInputWindowDamage -> refresh callback.
    // With this scope live, that callback is dropped instead of starting a
    // second paint on top of this one.
    rni::GlfwSurface::PaintScope paintScope(&surface);
    TRACE_EVENT0("frame", "Frame");
    ImpellerDisplayListBuilder builder = ImpellerDisplayListBuilderNew(nullptr);
    int painted;
    {
      TRACE_EVENT0("paint", "PaintWalk");
      painted = sceneGraph.paint(builder, pointScale);
    }
    ImpellerDisplayList dl;
    {
      TRACE_EVENT0("paint", "DisplayListBuild");
      dl = ImpellerDisplayListBuilderCreateDisplayListNew(builder);
    }
    frame->RecordBuildEnd();
    frame->RecordRasterStart();
    if (dl) {
      TRACE_EVENT0("raster", "Draw");
      surface.drawDisplayList(dl);
      ImpellerDisplayListRelease(dl);
    }
    ImpellerDisplayListBuilderRelease(builder);
    frame->RecordRasterEnd();
    if (grabArmed) {
      grabOk = surface.readPixels(&grabPx);
      grabArmed = false;
    }
    if (rni::animrow::Enabled()) {  // FP-10 test hook, see AnimRowProbe.h
      std::vector<rni::Px> rowPx;
      if (surface.readPixels(&rowPx)) {
        rni::animrow::OnPresent(rowPx, surface.width(), surface.height(),
                                paintsTotal + 1,
                                rni::ReactHost::animationClockFrames());
      }
    }
    {
      TRACE_EVENT0("raster", "Present");
      scheduler.WillPresent();
      surface.present();
      scheduler.DidPresent(paintsTotal + 1);
    }
    frame->RecordPresent();
    frame->SetImageCacheBytes(rni::image::CacheBytes());  // FP-33
    frameTimings.Commit(std::move(frame));
    TRACE_COUNTER("presents", paintsTotal + 1);
    // ⛔ COUNTED HERE, AT THE PRESENT, NOT AT THE CALLER.
    // refreshPaints is derived from this counter, so "a frame was painted
    // during the stall" is measured at the only place a frame actually
    // reaches the screen. Counting in the refresh handler instead would let a
    // handler that increments a variable and never paints report success --
    // precisely the mark-only trap this fix exists to avoid, and exactly what
    // the M2 mutant in tools/mutation-verify-resize.sh does.
    ++paintsTotal;
    rni::glvalidation::OnFrame();  // FP-05 test hook
    rni::image::OnFrame();         // FP-33 test hook (RNI_TEST_LOW_MEMORY_AT_FRAME)
    // ⛔ firstFramePresented: THE APP'S "YOU ARE ON SCREEN NOW" SIGNAL.
    // Emitted once, after the first present returns, so a launch animation
    // can start its clock from the moment pixels reach the window instead of
    // from JS start. DeviceEventEmitter.addListener('firstFramePresented').
    // Payload sinceLaunchMs = process start -> this present (wall ms).
    if (paintsTotal == 1) {
      const int ms = SinceLaunchMs();
      printf("rn-impeller: first_present_ms=%d\n", ms);
      fflush(stdout);
      folly::dynamic payload = folly::dynamic::object("sinceLaunchMs", ms);
      host.deviceEvents()->emit("firstFramePresented", payload);
    }
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
    // A refresh paint is its own frame: it begins here, not at a loop vsync.
    auto frame = std::make_unique<rni::FrameTimingsRecorder>();
    frame->RecordVsync();
    frame->RecordBuildStart();
    applyResizeIfDirty();
    paintFrame(std::move(frame));
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
    if (!down) fabric.endTextSelectionDrag();  // item 4b
    // item 6: the left button ALSO gets W3C pointer events (button 0,
    // detail = click count, live modifiers), alongside its RN touch.
    {
      const auto md = surface.lastMods();
      fabric.dispatchPointerButton(x, y, down, 0, surface.heldButtonsMask(),
                                   surface.lastClickCount(), md.shift, md.ctrl,
                                   md.alt, md.meta);
    }
    if (down) {
      // <TextInput>. ENG-01b. A press also (re)assigns keyboard focus: click a
      // field to edit it, click elsewhere to blur. This must run on the DOWN so
      // the caret appears on the same click that a user expects it to, and is
      // separate from the touch dispatch above -- a field both receives the
      // press (for onPressIn-style handlers) AND takes focus.
      // item 4b: the click count (double = word, triple = line) and Shift
      // (extend) come from the surface, which counted this press.
      const int focused = fabric.focusTextInputAt(
          x, y, surface.lastClickCount(), surface.lastPressShift());
      // P1 item 15: the same press starts (or clears) a selectable-<Text>
      // selection. A press that focused a field cannot also be on text.
      if (focused == 0) fabric.beginTextSelection(x, y, surface.lastClickCount());
      printf("rn-impeller: textinput_focus=%d at=%.1f,%.1f clicks=%d\n",
             focused, x, y, surface.lastClickCount());
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

  // item 6. Right/middle/back/forward: W3C pointer events ONLY. Deliberately
  // no beginTouchCapture (no Pressable onPress) and no focusTextInputAt (a
  // right click must not move the caret or steal focus).
  surface.setExtraButtonHandler(
      [&](const rni::GlfwSurface::ExtraButtonEvent& ev) {
        fabric.dispatchPointerButton(ev.x, ev.y, ev.down, ev.button,
                                     ev.buttons, ev.clickCount, ev.shift,
                                     ev.ctrl, ev.alt, ev.meta);
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
    // item 4b: a drag that began in a TextInput extends its selection. Checked
    // on its own, not only under isTouchCaptured(): a press on a field whose
    // emitter took no touch capture must still drag-select.
    const bool selectionDrag = fabric.dragTextSelection(x, y);
    if (fabric.isTouchCaptured()) {
      fabric.dispatchCapturedMove(x, y);
      return lastLoggedCursor < 0 ? 0 : lastLoggedCursor;
    }
    if (selectionDrag) return lastLoggedCursor < 0 ? 0 : lastLoggedCursor;
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
      printf("rn-impeller: cursor=%s\n", rni::CursorKindName(r.cursorKind));
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

  // desktop-input-gap P0 item 1. FULL keyboard forwarding to JS: every key
  // press/repeat/release, with modifiers, routed into
  // FabricHost::dispatchKeyEvent (onKeyPress on the focused TextInput, plus
  // a generic keyDown/keyUp on whatever is focused or the surface root).
  // Installed ALONGSIDE the legacy char/key handlers above, not instead of
  // them: those still own Backspace/Enter single-line editing byte for byte
  // (ci-textedit.sh's regression guard), and the char callback stays the
  // ONLY source of typed characters. This handler's printed line is the one
  // machine-readable proof a gate needs that a key of ANY kind, not just
  // Backspace/Enter, reached the host at all.
  surface.setFullKeyHandler([&](const rni::GlfwSurface::KeyEvent& ev) {
    rni::FabricHost::KeyModifiers mods;
    mods.shift = ev.shift;
    mods.ctrl = ev.ctrl;
    mods.alt = ev.alt;
    mods.meta = ev.meta;
    mods.capsLock = ev.capsLock;
    const rni::FabricHost::KeyEventPhase phase =
        ev.phase == rni::GlfwSurface::KeyPhase::Up
            ? rni::FabricHost::KeyEventPhase::Up
        : ev.phase == rni::GlfwSurface::KeyPhase::Repeat
            ? rni::FabricHost::KeyEventPhase::Repeat
            : rni::FabricHost::KeyEventPhase::Down;
    const int tag = fabric.dispatchKeyEvent(ev.key, ev.code, phase, mods);
    const char* typeStr = ev.phase == rni::GlfwSurface::KeyPhase::Up ? "up"
                         : ev.phase == rni::GlfwSurface::KeyPhase::Repeat
                             ? "repeat"
                             : "down";
    printf(
        "rn-impeller: key_event type=%s key=%s code=%s "
        "mods=shift:%d,ctrl:%d,alt:%d,meta:%d,caps:%d scancode=%d tag=%d\n",
        typeStr, ev.key.c_str(), ev.code.c_str(), (int)ev.shift, (int)ev.ctrl,
        (int)ev.alt, (int)ev.meta, (int)ev.capsLock, ev.scancode, tag);
    fflush(stdout);
  });

  // Reads the framebuffer and writes a PPM. Shared by the frame-0 and the
  // timed capture so the two images are produced by literally the same code
  // path -- if they differed in how they were read back, a difference between
  // them would not prove anything about repainting.
  // The pixels come from grabPx, filled PRE-PRESENT inside paintFrame (see
  // grabArmed above); reading fbo 0 here, after the swap, is the darwin
  // all-zero bug.
  auto capture = [&](const std::string& path, const char* label) {
    if (path.empty()) return;
    if (!grabOk) {
      fprintf(stderr, "rn-impeller: WARN: %s readback failed (%s)\n", label,
              path.c_str());
      return;
    }
    if (!rni::GlfwSurface::writePpm(path, grabPx, surface.width(),
                                    surface.height()))
      return;
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                  std::chrono::steady_clock::now() - start)
                  .count();
    printf("rn-impeller: %s=%s frame=%d elapsed_ms=%lld\n", label, path.c_str(),
           frameIndex, (long long)ms);
    fflush(stdout);
  };

  // ── P12-01: idle-frame damage-skip wake wiring ─────────────────────────────
  // The retained SceneGraph repaints every frame regardless of change; on an
  // idle window that pins a CPU core. --idle-skip makes a CLEAN frame skip the
  // paint AND block in glfwWaitEventsTimeout so the thread sleeps (skipping the
  // paint alone still busy-spins the non-blocking poll — the sleep is the fix).
  // Install glfwPostEmptyEvent as the damage wake on every OFF-thread source
  // (SceneGraph::bumpVersion covers the JS thread's applyMutations /
  // updateViewProps / text-input paths) so a change while the loop sleeps
  // repaints promptly. M3 installs NO wake, so the off-thread witness stalls the
  // full budget, proving the wake is load-bearing. Wired only under --idle-skip:
  // every existing gate keeps its unconditional paint-every-frame loop.
  if (idleSkip) {
    // FP-11: every damage source is a frame request; the scheduler posts the
    // wake (glfwPostEmptyEvent) unless M3 built it without one.
    sceneGraph.setDamageWake([&scheduler]() { scheduler.RequestFrame("damage"); });
    host.setNativeAnimatedStartHook([&scheduler]() { scheduler.RequestFrame("animation"); });
    // FP-40: a LayoutAnimation starts inside a JS-thread pull.
    fabric.setLayoutAnimationWake([&scheduler]() { scheduler.RequestFrame("layout_animation"); });
    {
      // ENG-09: a WorldRaster.setPixels write is scene damage the version
      // counter is otherwise blind to (it runs on the JS thread and never
      // touches the scene graph). Route it through bumpVersion() — the SAME
      // signal a Fabric commit uses — so the next frame is dirty AND a loop
      // asleep in glfwWaitEventsTimeout wakes. Without this the animation
      // freezes on the last painted frame under the default windowed idle-skip.
      // It reaches the scheduler through bumpVersion, so M3 (no wake) also
      // covers the store path and its off-thread witness stalls the full budget.
      host.worldRasterStore()->setDamageHook(
          [&sceneGraph]() { sceneGraph.bumpVersion(); });
    }
    if (idleMutant == 3) {
      printf("rn-impeller: [idle] MUTANT M3: damage wake NOT installed\n");
      fflush(stdout);
    }
    printf("rn-impeller: [idle] enabled budget_ms=%d mutant=%d run_sec=%.2f\n",
           idleBudgetMs, idleMutant, idleRunSec);
    fflush(stdout);
  }

  // ENG-18: windowed --type. Settle the mount, focus the field at X,Y (layout
  // points, the same coordinates headless --type takes), then feed ONE token
  // per frame through the real windowed entry points: characters through
  // GlfwSurface::synthesiseChar (the char callback's handler) and Enter /
  // Shift+Enter / Backspace through GlfwSurface::synthesiseKey (the key
  // callback's translation, so onKeyPress, keyDown and the editing handler
  // all run exactly as for a real keystroke). Then print the same
  // textinput_value + paragraph report headless prints, capture --screenshot
  // two frames later, and exit unless --frames / --idle-run-sec ask for more.
  std::vector<TypeToken> typeTokens;
  float typeX = 0.0f, typeY = 0.0f;
  const bool typePlan = !gWindowedTypeSpec.empty();
  if (typePlan) {
    const auto colon = gWindowedTypeSpec.find(':');
    if (colon == std::string::npos ||
        std::sscanf(gWindowedTypeSpec.substr(0, colon).c_str(), "%f,%f",
                    &typeX, &typeY) != 2) {
      fprintf(stderr, "rn-impeller: FATAL: --type wants X,Y:SEQ (got '%s')\n",
              gWindowedTypeSpec.c_str());
      return 1;
    }
    typeTokens = ParseTypeSeq(gWindowedTypeSpec.substr(colon + 1));
    printf("rn-impeller: type_window tokens=%zu at=%.1f,%.1f\n",
           typeTokens.size(), typeX, typeY);
    fflush(stdout);
  }
  int typeFocusTag = -1;  // -1 = not focused yet
  size_t typeNext = 0;
  bool typeDone = !typePlan;
  int typeDoneFrame = -1;
  const auto typeStart = std::chrono::steady_clock::now();

  // Any frame-anchored test hand not yet fully consumed keeps the loop
  // painting, so resize/stall/click/scroll/hover/screenshot gates and any
  // bounded --frames N run keep their exact frame counts. A --frames run
  // paints every frame by construction (idle gate uses --idle-run-sec, an
  // unbounded loop with a wall-clock exit, NOT --frames).
  auto handsPending = [&]() -> bool {
    return frames > 0 ||
           (resizeAfterFrames > 0 && frameIndex <= resizeAfterFrames + 5) ||
           (stallAfterFrames > 0 && frameIndex <= stallAfterFrames) ||
           (clickAfterFrames > 0 && frameIndex <= clickAfterFrames) ||
           (scrollAfterFrames > 0 && frameIndex <= scrollAfterFrames) ||
           (hoverAfterFrames > 0 &&
            frameIndex <= hoverAfterFrames + (int)hoverPoints.size()) ||
           (keyAfterFrames > 0 &&
            frameIndex <= keyAfterFrames + (int)keySequence.size()) ||
           (charAfterFrames > 0 &&
            frameIndex <= charAfterFrames + (int)charSequence.size()) ||
           (mouseAfterFrames > 0 &&
            frameIndex <= mouseAfterFrames + (int)mouseSequence.size()) ||
           (!screenshotFirstPath.empty() && !capturedFirst) ||
           (!screenshotPath.empty() && !capturedTimed) ||
           (typePlan && (!typeDone || frameIndex <= typeDoneFrame + 3));
  };

  while (!surface.shouldClose()) {
    auto loopFrame = std::make_unique<rni::FrameTimingsRecorder>();
    // FP-11: the loop's own requests. Without --idle-skip every iteration is a
    // frame (the old paint-every-frame loop, now paced by vsync); with it only
    // the first frame and a pending test hand ask here. Everything else
    // (damage, NativeAnimated start, a live clock, resize) requests itself.
    if (!idleSkip || frameIndex == 0 || handsPending()) scheduler.RequestFrame("loop");
    if (scheduler.FramePending()) scheduler.AwaitVsync();
    loopFrame->RecordVsync();
    surface.pollEvents();

    // The loop's caller of the shared resize body. This is the path that runs
    // in the normal (non-drag) case; the window-refresh callback installed
    // above is the path that runs when this loop is blocked inside
    // pollEvents(). Both go through applyResizeIfDirty, deliberately.
    if (applyResizeIfDirty()) scheduler.RequestFrame("resize");

    // item 5. Drain the ClipboardBridge's queued main-thread tasks every
    // iteration, same discipline as applyResizeIfDirty: a getString()/
    // setString() call from the JS thread posts here and waits for this
    // drain (or the bridge's wake, under --idle-skip) to run it.
    clipboard->drainMain();
    // item 7: view commands (scrollTo, focus, setTextAndSelection) queued by
    // the JS thread; applied here, on the thread that owns input + paint.
    fabric.drainMain();

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

    // ── FP-11: BeginFrame (was P12-01's damage computation) ──────────────────
    // No request, no frame. Without --idle-skip the loop requested above, so
    // every iteration paints exactly as before. With it a clean iteration skips
    // the paint and SLEEPS below (that sleep, not the paint-skip, is what drops
    // CPU). M1 forces a frame every iteration so the CPU gate fails.
    loopFrame->RecordBuildStart();
    const bool shouldPaint =
        (idleSkip && idleMutant == 1) ? true : scheduler.FramePending();
    // ENG-06: advance RN's animation engine once per frame, BEFORE painting,
    // so this frame shows the value this tick produced (BeginFrame fan-out:
    // Animator::BeginFrame -> OnAnimatorBeginFrame).
    bool animatedThisFrame = false;
    if (shouldPaint) {
      scheduler.BeginFrame();
      // FP-40: RN's animationTick (LayoutAnimation half), platform thread.
      if (fabric.tickLayoutAnimations()) animatedThisFrame = true;
      const unsigned long ticksBefore = host.nativeAnimatedTicks();
      host.pumpNativeAnimated();
      if (host.nativeAnimatedTicks() != ticksBefore) animatedThisFrame = true;
    }
    // A live clock asks for the next frame: a NativeAnimated animation in
    // flight, a focused field's caret blink, a spinning ActivityIndicator.
    // Nothing marks those dirty, so without this they freeze mid-cycle.
    if (idleSkip && (animatedThisFrame || host.nativeAnimatedActive() ||
                     fabric.layoutAnimationActive() ||
                     sceneGraph.focusedTextInput() != 0 ||
                     sceneGraph.spinnerAnimating())) {
      scheduler.RequestFrame("clock");
    }

    // Decide BEFORE the paint which captures this frame serves, and arm the
    // pre-present readback for it. Deciding after the paint (as before) read
    // fbo 0 post-swap -- all zeros on darwin.
    const bool wantFirst = shouldPaint && !capturedFirst && frameIndex == 0 &&
                           !screenshotFirstPath.empty();
    const long long sinceStartMs =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start)
            .count();
    // ENG-18: with a windowed --type plan, --screenshot waits for the typing
    // to finish (plus two frames for the JS re-render to mount), with or
    // without --screenshot-after.
    const bool typeCaptureReady =
        typePlan && typeDone && frameIndex >= typeDoneFrame + 2;
    const bool wantTimed =
        shouldPaint && !screenshotPath.empty() && !capturedTimed &&
        (typePlan ? (typeCaptureReady && (screenshotAfterMs < 0 ||
                                          sinceStartMs >= screenshotAfterMs))
                  : (screenshotAfterMs >= 0 &&
                     sinceStartMs >= screenshotAfterMs));
    grabOk = false;
    grabArmed = wantFirst || wantTimed;

    int painted = 0;
    if (shouldPaint) painted = paintFrame(std::move(loopFrame));
    else frameTimings.Discard(std::move(loopFrame));
    grabArmed = false;
    ++frameIndex;
    if (shouldPaint && frameIndex == 1) {
      printf("rn-impeller: painted_nodes=%d\n", painted);
      printf("rn-impeller: world_sprites_drawn=%d\n",
             sceneGraph.worldSpritesDrawn());
    }

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

    // desktop-input-gap P0 item 1. SYNTHETIC-KEY HOOK -- weaker evidence,
    // exactly like the click/scroll/hover hooks above: it calls
    // GlfwSurface::synthesiseKey, which enters the identical translation +
    // dispatchKeyEvent path a real glfwSetKeyCallback does, but is NOT proof
    // glfwSetKeyCallback is registered (deleting that registration leaves
    // this hook passing). tools/ci-key-events.sh pairs it with a REAL XTest
    // key event for the registration arm; this hook exists for modifier
    // combinations some window managers refuse to let XTest deliver (Super)
    // and so the gate is host-independent for the rest.
    //
    // One KeySpec is consumed per frame starting at keyAfterFrames, same
    // one-per-frame discipline as the hover sequence above.
    if (keyAfterFrames > 0 && frameIndex >= keyAfterFrames &&
        !keySequence.empty()) {
      const size_t idx = (size_t)(frameIndex - keyAfterFrames);
      if (idx < keySequence.size()) {
        const auto& ks = keySequence[idx];
        rni::GlfwSurface::KeyMods mods;
        mods.shift = ks.shift;
        mods.ctrl = ks.ctrl;
        mods.alt = ks.alt;
        mods.meta = ks.meta;
        mods.capsLock = ks.capsLock;
        const rni::GlfwSurface::KeyPhase phase =
            ks.phase == 2   ? rni::GlfwSurface::KeyPhase::Up
            : ks.phase == 1 ? rni::GlfwSurface::KeyPhase::Repeat
                            : rni::GlfwSurface::KeyPhase::Down;
        printf("rn-impeller: key_requested key=%s phase=%d\n", ks.key.c_str(),
               ks.phase);
        fflush(stdout);
        if (!surface.synthesiseKey(ks.key, phase, mods)) {
          fprintf(stderr,
                  "rn-impeller: FATAL: --key-after-frames key '%s' has no "
                  "known GLFW mapping\n",
                  ks.key.c_str());
          return 1;
        }
        host.waitForJsIdle(5000);
      }
    }

    // desktop-input-gap item 2a. SYNTHETIC-CHAR HOOK. One CharSpec consumed
    // per frame starting at charAfterFrames -- same one-per-frame discipline
    // as the key/hover sequences above, and the same "weaker evidence"
    // caveat (GlfwSurface::synthesiseChar calls charHandler_ directly; it is
    // NOT proof glfwSetCharCallback is registered -- that registration is
    // already covered by ci-key-events.sh's real-XTest arm, whose Ctrl+A/
    // Escape/Delete keys exercise the SAME callback-registration bug class).
    if (charAfterFrames > 0 && frameIndex >= charAfterFrames &&
        !charSequence.empty()) {
      const size_t idx = (size_t)(frameIndex - charAfterFrames);
      if (idx < charSequence.size()) {
        const auto& cs = charSequence[idx];
        printf("rn-impeller: char_requested cp=%u\n", cs.codepoint);
        fflush(stdout);
        if (!surface.synthesiseChar(cs.codepoint)) {
          fprintf(stderr,
                  "rn-impeller: FATAL: --char-after-frames: no char handler "
                  "installed\n");
          return 1;
        }
        host.waitForJsIdle(5000);
      }
    }

    // ENG-18: the windowed --type plan (see its state above the loop).
    if (typePlan && !typeDone && frameIndex >= 2) {
      if (typeFocusTag < 0) {
        // Same mount settle as headless --type: poll for a REAL TextInput
        // under the point, bounded, so a never-mounting field fails loudly.
        const long long waited =
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - typeStart)
                .count();
        if (!fabric.isTextInputAt(typeX, typeY) && waited < 10000) {
          host.waitForJsIdle(200);
        } else {
          printf("rn-impeller: type_mount_settle_ms=%lld field=%d\n", waited,
                 (int)fabric.isTextInputAt(typeX, typeY));
          typeFocusTag = fabric.focusTextInputAt(typeX, typeY);
          printf("rn-impeller: type_focus=%d at=%.1f,%.1f\n", typeFocusTag,
                 typeX, typeY);
          fflush(stdout);
          host.waitForJsIdle(5000);
        }
      } else if (typeNext < typeTokens.size()) {
        const TypeToken& tk = typeTokens[typeNext++];
        auto pressKey = [&](const char* name, bool shift) {
          rni::GlfwSurface::KeyMods mods;
          mods.shift = shift;
          surface.synthesiseKey(name, rni::GlfwSurface::KeyPhase::Down, mods);
          surface.synthesiseKey(name, rni::GlfwSurface::KeyPhase::Up, mods);
        };
        switch (tk.kind) {
          case TypeToken::Char:
            surface.synthesiseChar(tk.codepoint);
            break;
          case TypeToken::Backspace:
            pressKey("Backspace", false);
            break;
          case TypeToken::Enter:
            pressKey("Enter", false);
            break;
          case TypeToken::ShiftEnter:
            pressKey("Enter", true);
            break;
          case TypeToken::SelectAll:
            fabric.dispatchKey(rni::FabricHost::KeyAction::SelectAll, 0);
            break;
          case TypeToken::Copy:
            fabric.dispatchKey(rni::FabricHost::KeyAction::Copy, 0);
            break;
          case TypeToken::Cut:
            fabric.dispatchKey(rni::FabricHost::KeyAction::Cut, 0);
            break;
        }
        host.waitForJsIdle(5000);
      } else {
        host.waitForJsIdle(5000);
        // Read the field the plan focused, even if Enter blurred it since.
        const int tag = typeFocusTag;
        const std::string v = sceneGraph.textInputValueFor(tag);
        const size_t caret = sceneGraph.textInputCaretFor(tag);
        printf("rn-impeller: textinput_value tag=%d len=%zu caret=%zu v=%s\n",
               tag, v.size(), caret, EscapeNewlines(v).c_str());
        fputs(sceneGraph.paragraphTextReport().c_str(), stdout);
        printf("rn-impeller: type_done frame=%d\n", frameIndex);
        fflush(stdout);
        typeDone = true;
        typeDoneFrame = frameIndex;
      }
    }


    // item 4b. SYNTHETIC MOUSE HOOK: one press/release/move per frame through
    // GlfwSurface::synthesiseMouse (the same dispatchCursorPoint /
    // dispatchHoverPoint the real callbacks use, so click counting and drag
    // routing are exercised). Weaker evidence than a real XTest drag, which
    // ci-select-mouse.sh also runs.
    if (mouseAfterFrames > 0 && frameIndex >= mouseAfterFrames &&
        !mouseSequence.empty()) {
      const size_t idx = (size_t)(frameIndex - mouseAfterFrames);
      if (idx < mouseSequence.size()) {
        const auto& ms = mouseSequence[idx];
        printf("rn-impeller: mouse_requested op=%d at=%.1f,%.1f shift=%d\n",
               ms.op, ms.x, ms.y, ms.shift ? 1 : 0);
        fflush(stdout);
        if (ms.button >= 0 && ms.op != 2) {
          surface.synthesiseMouseButton(ms.button, ms.op == 0, ms.x, ms.y,
                                        ms.shift, ms.ctrl, ms.alt, ms.meta);
        } else {
          surface.synthesiseMouse(ms.op, ms.x, ms.y, ms.shift);
        }
        // Wait for JS only after the LAST event. Waiting after each one
        // spaced presses ~450 ms apart, at the edge of the 500 ms
        // double-click interval, which a real mouse never does (GLFW
        // callbacks do not wait for JS). One event per frame (~16 ms) keeps
        // a synthetic double click as tight as a human one.
        if (idx + 1 == mouseSequence.size()) host.waitForJsIdle(5000);
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
    if (!capturedFirst && frameIndex == 1 && !screenshotFirstPath.empty() &&
        wantFirst) {
      capture(screenshotFirstPath, "screenshot_first");
      capturedFirst = true;
    }

    if (wantTimed && !capturedTimed) {
      capture(screenshotPath, "screenshot");
      capturedTimed = true;
    }

    // ── P12-01: off-thread repaint witness + idle sleep + run-window exit ─────
    if (idleSkip) {
      // OFF-THREAD REPAINT WITNESS. At the requested frame, spawn a detached
      // thread that bumps the scene version once after a short delay -- the JS-
      // thread applyMutations path in miniature. On HEAD the bump fires the
      // damage wake (glfwPostEmptyEvent), so the sleep below returns early and a
      // repaint follows; the gate measures the frame gap. Under M3 no wake is
      // installed, so the loop sleeps out the full budget. Fired once.
      if (idleOffthreadAfter >= 0 && frameIndex == idleOffthreadAfter) {
        printf("rn-impeller: [idle] offthread_fire frame=%d version=%llu\n",
               frameIndex, (unsigned long long)sceneGraph.version());
        fflush(stdout);
        std::thread([&sceneGraph]() {
          // Small delay so the loop is actually parked in glfwWaitEventsTimeout
          // when the bump lands -- the exact race the wake exists for.
          std::this_thread::sleep_for(std::chrono::milliseconds(30));
          sceneGraph.bumpVersion();
        }).detach();
      }

      const bool clean = !shouldPaint;
      int sleptMs = 0;
      // A request that landed after the decision posted its wake already, so
      // the wait below returns at once; skip it outright when one is pending.
      // THE SLEEP THAT DROPS CPU. Block up to budget ms; any input OR a posted
      // wake returns early. M2 deliberately KEEPS the non-blocking poll (no
      // sleep) so the loop busy-spins -- the CPU gate must catch that exact
      // wrong fix, proving the sleep, not the paint-skip, is what matters.
      if (clean && idleMutant != 2 && !scheduler.FramePending()) {
        const auto t0 = std::chrono::steady_clock::now();
        surface.waitEvents((double)idleBudgetMs / 1000.0);
        sleptMs = (int)std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now() - t0)
                      .count();
      }
      if (idleLog) {
        printf("rn-impeller: [idle] frame=%d dirty=%d painted=%d slept_ms=%d "
               "version=%llu\n",
               frameIndex, clean ? 0 : 1, shouldPaint ? 1 : 0, sleptMs,
               (unsigned long long)sceneGraph.version());
        fflush(stdout);
      }
      // --idle-run-sec: hold the window open with no input for the window, then
      // exit 0. This is what the idle-CPU gate samples %CPU across.
      if (idleRunSec > 0.0 &&
          std::chrono::duration<double>(std::chrono::steady_clock::now() -
                                        start)
                  .count() >= idleRunSec) {
        printf("rn-impeller: [idle] run window elapsed after %.2fs, frames=%d\n",
               idleRunSec, frameIndex);
        fflush(stdout);
        break;
      }
    }

    // ENG-18: a --type plan holds the run open until the typing and its
    // capture are done (30 s wall cap), then ends it unless --frames or
    // --idle-run-sec ask for a longer run.
    if (typePlan) {
      const bool typeFinished = typeDone && frameIndex > typeDoneFrame + 2 &&
                                (screenshotPath.empty() || capturedTimed);
      const double typeWall = std::chrono::duration<double>(
                                  std::chrono::steady_clock::now() - typeStart)
                                  .count();
      if (!typeFinished && typeWall > 30.0) {
        fprintf(stderr,
                "rn-impeller: FATAL: windowed --type did not finish in 30 s "
                "(focus=%d, %zu/%zu tokens)\n",
                typeFocusTag, typeNext, typeTokens.size());
        break;
      }
      if (!typeFinished) continue;
      if (frames <= 0 && idleRunSec <= 0.0) break;
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
  surface.setExtraButtonHandler(nullptr);  // item 6
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
  // desktop-input-gap P0 item 1. Same lifetime argument again.
  surface.setFullKeyHandler(nullptr);
  // P12-01: drop the damage wake before teardown. It captures `surface` by
  // reference; clearing it here means no late off-thread bump can post an event
  // to a window mid-destruction. Safe even though the JS thread is already torn
  // down by this point -- belt and braces, same discipline as the handlers.
  sceneGraph.setDamageWake(nullptr);
  host.setNativeAnimatedStartHook(nullptr);  // FP-11: captures `scheduler`


  // Machine-readable evidence that the modal-loop repaint path executed. A
  // gate asserting only on pixels cannot tell a mid-drag repaint from the
  // single post-release repaint that was already happening.
  printf("rn-impeller: refresh_paints=%d\n", refreshPaints);
  // FP-01: presents counted at surface.present(), independent of the recorder.
  printf("rn-impeller: presents=%d\n", paintsTotal);
  {  // FP-54: frames handed to React Native DevTools (0 unless a trace recorded)
    const rni::devtools::Stats dt = rni::devtools::GetStats();
    printf("rn-impeller: devtools_frames sessions=%llu commits=%llu emitted=%llu\n",
           (unsigned long long)dt.sessions, (unsigned long long)dt.commits,
           (unsigned long long)dt.emitted);
  }
  scheduler.PrintSummary();
  fabric.printLayoutAnimationSummary();  // FP-40
  FinishFrameTimings(frameTimings);
  FinishTrace();
  rni::glvalidation::Finish();
  rni::image::PrintStats();  // FP-16
  rni::typography::PrintSummary();  // FP-12
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
  // ENG-18: an unfinished --type plan is a failed run, not a quiet exit.
  if (typePlan && !typeDone) return 4;
  return 0;
}
#endif  // RNI_WITH_WINDOW

// parity item 14: the original argv, for DevSettings.reload's re-exec.
static std::vector<std::string> gArgv;

// parity item 14. Replace this process with a fresh copy of itself, same
// argv. Never returns on success.
[[noreturn]] static void ReexecForReload(const std::string& reason) {
  printf("rn-impeller: reload_reexec reason=%s\n", reason.c_str());
  fflush(stdout);
  fflush(stderr);
  std::vector<char*> args;
  for (auto& a : gArgv) args.push_back(const_cast<char*>(a.c_str()));
  args.push_back(nullptr);
#if defined(_WIN32)
  _execv(args[0], args.data());
#else
  execv("/proc/self/exe", args.data());  // linux: robust to a relative argv[0]
  execv(args[0], args.data());            // darwin / fallback
#endif
  fprintf(stderr, "rn-impeller: FATAL: reload re-exec failed\n");
  _exit(1);
}

int main(int argc, char** argv) {
  for (int i = 0; i < argc; ++i) gArgv.emplace_back(argv[i]);
  // MUST be first: ReactNativeFeatureFlags::override() throws once any flag has
  // been read, and plenty of construction paths read one.
  rni::installFeatureFlags();
  rni::trace::SetThreadName("main");
  rni::sanitize::RunTestHooks();
  // FP-33: env defaults for hosts without argv (Android); --image-cache-mb below overrides.
  if (const char* e = std::getenv("RNI_IMAGE_CACHE_MB")) rni::image::SetCacheBudget((int64_t)(atof(e) * 1048576.0));
  if (const char* e = std::getenv("RNI_IMAGE_CACHE_FLOOR_MB")) rni::image::SetCacheFloor((int64_t)(atof(e) * 1048576.0));
  rni::memorypressure::Start();
#if RNI_FUZZ
  // FP-52: fuzz builds only. After the feature flags, which props parsing reads.
  if (rni::fuzz::Requested(argc, argv)) return rni::fuzz::Main(argc, argv);
#endif

  std::string bundlePath, appName, screenshot;
  std::string colorScheme = "light";
  bool colorSchemeGiven = false;
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
  // P12-01 idle-frame damage-skip. Default OFF for the HEADLESS/gate paths so
  // every screenshot/--frames gate keeps its unconditional paint-every-frame
  // loop. Under --window it now DEFAULTS ON (resolved post-parse below) so a
  // real idle window sleeps instead of pinning a core; --no-idle-skip opts out.
  // idleSkipSet tracks an explicit --idle-skip / --no-idle-skip so the windowed
  // default never overrides what the caller asked for.
  bool idleSkip = false;
  bool idleSkipSet = false;
  double idleRunSec = 0.0;
  int idleBudgetMs = 250;
  bool idleLog = false;
  int idleMutant = 0;
  int idleOffthreadAfter = -1;
  int frames = 0;              // 0 = unbounded, run until window closes
  std::string tapSpec;         // "X,Y" in points; empty = no input probe
  // <TextInput>. ENG-01b. Headless editing probe. "--type X,Y:SEQ" focuses the
  // field under (X,Y) POINTS, then replays SEQ one token at a time through the
  // SAME FabricHost::focusTextInputAt / dispatchKey path the GLFW callbacks use,
  // so the whole editing loop (focus -> keystroke -> buffer -> onChange) is
  // gate-provable with no window. SEQ is literal ASCII plus the escapes <BS>
  // (backspace), <CR> (submit/Enter), and <SA>/<COPY>/<CUT> (select all,
  // copy, cut; style audit item 11). Exists for exactly the reason --tap
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
  // desktop-input-gap P0 item 1. Windowed keyboard test hook state (KeySpec
  // is file-scope, above RunWindowed). See the flag parser below for the
  // "--key-after-frames N:KEY:PHASE[:MODS];..." syntax.
  int keyAfterFrames = 0;
  std::vector<KeySpec> keySequence;
  // desktop-input-gap item 2a. Windowed synthetic-char test hook state
  // (CharSpec is file-scope, above RunWindowed). See the flag parser below
  // for the "--char-after-frames N:CP1;CP2;..." syntax.
  int charAfterFrames = 0;
  std::vector<CharSpec> charSequence;
  // item 4b. "--mouse-after-frames N:OP@X,Y;..." OP = down|up|move|sdown
  // (sdown = press with Shift). One event per frame from frame N.
  int mouseAfterFrames = 0;
  std::vector<MouseSpec> mouseSequence;
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
  // emit. Default 4 on darwin (where the tessellated-AA gap was measured) and on
  // Windows (ANGLE D3D11 shows the same gap: 3 luma levels on the HostApp icon rail
  // at N=0), 0 (disabled, exact in-place path) on linux, whose gates pin it.
  // --supersample-rnsvg overrides.
#if defined(__APPLE__) || defined(_WIN32)
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
    else if (a == "--frame-timings-out") gFrameTimingsOut = next("--frame-timings-out");
    else if (a == "--trace-out") {
      gTraceOut = next("--trace-out");
      rni::trace::Start(gTraceOut);
    } else if (a == "--trace-bench") return RunTraceBench(atol(next("--trace-bench").c_str()));
    // ── P12-01 idle-frame damage-skip flags ──────────────────────────────────
    //   --idle-skip           enable the dirty-frame skip + glfwWaitEventsTimeout
    //                         sleep (default OFF so every existing gate keeps its
    //                         paint-every-frame behaviour unchanged).
    //   --idle-run-sec S      run the window with no input for S seconds then
    //                         exit 0. The idle-CPU gate samples %CPU across this.
    //   --idle-budget-ms M    glfwWaitEventsTimeout sleep bound in ms (def 250).
    //   --idle-log            print `[idle] frame=... dirty=... painted=...
    //                         slept_ms=...` each iteration so a gate can prove
    //                         skips happened.
    //   --idle-mutant N       1=M1 always-dirty, 2=M2 skip paint but keep the
    //                         non-blocking poll (no sleep), 3=M3 never install
    //                         the wake. For mutation-verify ONLY.
    //   --idle-offthread-after F  at frame F fire an OFF-thread scene bump once;
    //                         the off-thread repaint witness uses it with
    //                         --idle-log to prove M3 stalls and HEAD wakes.
    // FP-11: --vsync auto|swap|software|off|platform (default auto: swap
    // interval 1, software 60 Hz clock if the swap does not block; a bounded
    // --frames N run defaults to platform, see below); --vsync-log prints
    // vsync_request / vsync_present lines for tools/ci-vsync.sh.
    else if (a == "--vsync") {
      const std::string v = next("--vsync");
      gVsyncSet = true;
      if (!rni::FrameScheduler::ParseSource(v.c_str(), &gVsyncSource)) {
        fprintf(stderr, "rn-impeller: FATAL: --vsync wants auto|swap|software|off|platform (got '%s')\n", v.c_str());
        return 2;
      }
    } else if (a == "--vsync-log") gVsyncLog = true;
    else if (a == "--idle-skip") { idleSkip = true; idleSkipSet = true; }
    else if (a == "--no-idle-skip") { idleSkip = false; idleSkipSet = true; }
    else if (a == "--idle-run-sec") idleRunSec = atof(next("--idle-run-sec").c_str());
    else if (a == "--idle-budget-ms") idleBudgetMs = atoi(next("--idle-budget-ms").c_str());
    else if (a == "--idle-log") idleLog = true;
    else if (a == "--idle-mutant") idleMutant = atoi(next("--idle-mutant").c_str());
    else if (a == "--idle-offthread-after")
      idleOffthreadAfter = atoi(next("--idle-offthread-after").c_str());
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
    // desktop-input-gap P0 item 1. Windowed keyboard test hook:
    // "--key-after-frames N:KEY1:PHASE1[:MODS1];KEY2:PHASE2[:MODS2];..."
    // synthesises one key event per segment, one per frame starting at frame
    // N, through GlfwSurface::synthesiseKey -- the SAME translation the real
    // glfwSetKeyCallback uses (see dispatchKeyEvent's header comment), so
    // this hook exercises the conversion + dispatch on hosts where XTest
    // cannot reach every modifier (some window managers refuse to let XTest
    // set the Super/Meta bit). KEY is a W3C key name (ArrowLeft, Tab, a, ...);
    // PHASE is down/repeat/up; MODS is a comma list of shift,ctrl,alt,meta,
    // capslock (omit for none). Named to match the other frame-anchored
    // hooks (--click-after-frames, --hover-after-frames).
    else if (a == "--key-after-frames") {
      std::string spec = next("--key-after-frames");
      auto colon = spec.find(':');
      if (colon == std::string::npos) {
        fprintf(stderr,
                "rn-impeller: --key-after-frames wants N:KEY:PHASE[:MODS]... "
                "(got %s)\n",
                spec.c_str());
        return 2;
      }
      keyAfterFrames = atoi(spec.substr(0, colon).c_str());
      if (keyAfterFrames <= 0) {
        fprintf(stderr,
                "rn-impeller: --key-after-frames needs N > 0 (got %s)\n",
                spec.c_str());
        return 2;
      }
      std::string rest = spec.substr(colon + 1);
      size_t pos = 0;
      while (pos < rest.size()) {
        size_t semi = rest.find(';', pos);
        std::string seg = rest.substr(
            pos, semi == std::string::npos ? std::string::npos : semi - pos);
        if (!seg.empty()) {
          KeySpec ks;
          size_t c1 = seg.find(':');
          size_t c2 = c1 == std::string::npos ? std::string::npos
                                              : seg.find(':', c1 + 1);
          if (c1 == std::string::npos) {
            fprintf(stderr,
                    "rn-impeller: --key-after-frames segment wants "
                    "KEY:PHASE[:MODS] (got %s)\n",
                    seg.c_str());
            return 2;
          }
          ks.key = seg.substr(0, c1);
          std::string phaseStr =
              seg.substr(c1 + 1, c2 == std::string::npos ? std::string::npos
                                                         : c2 - c1 - 1);
          if (phaseStr == "down") ks.phase = 0;
          else if (phaseStr == "repeat") ks.phase = 1;
          else if (phaseStr == "up") ks.phase = 2;
          else {
            fprintf(stderr,
                    "rn-impeller: --key-after-frames phase must be "
                    "down/repeat/up (got %s)\n",
                    phaseStr.c_str());
            return 2;
          }
          if (c2 != std::string::npos) {
            std::string mods = seg.substr(c2 + 1);
            size_t mp = 0;
            while (mp < mods.size()) {
              size_t mc = mods.find(',', mp);
              std::string m = mods.substr(
                  mp, mc == std::string::npos ? std::string::npos : mc - mp);
              if (m == "shift") ks.shift = true;
              else if (m == "ctrl") ks.ctrl = true;
              else if (m == "alt") ks.alt = true;
              else if (m == "meta") ks.meta = true;
              else if (m == "capslock") ks.capsLock = true;
              else if (!m.empty()) {
                fprintf(stderr,
                        "rn-impeller: --key-after-frames unknown modifier "
                        "'%s'\n",
                        m.c_str());
                return 2;
              }
              if (mc == std::string::npos) break;
              mp = mc + 1;
            }
          }
          keySequence.push_back(ks);
        }
        if (semi == std::string::npos) break;
        pos = semi + 1;
      }
      if (keySequence.empty()) {
        fprintf(stderr,
                "rn-impeller: --key-after-frames needs at least one "
                "KEY:PHASE segment (got %s)\n",
                spec.c_str());
        return 2;
      }
    }
    // desktop-input-gap item 2a. Windowed synthetic-char test hook:
    // "--char-after-frames N:CP1;CP2;..." synthesises one CHARACTER event
    // per segment, one per frame starting at frame N, through
    // GlfwSurface::synthesiseChar -- the same charHandler_ a real
    // glfwSetCharCallback delivers to. CP is a decimal codepoint or
    // "U+XXXX" hex (e.g. "233" or "U+E9" for e-acute, "U+1F600" for an
    // emoji) -- accepting hex makes a gate's intent legible (U+1F600 reads
    // as "grinning face", 128512 does not) without adding a second field.
    // Exists because XTest cannot easily synthesise a raw keysym for
    // characters with no physical key on the host's layout (emoji, most
    // accented letters), so a gate needs an in-process path to prove
    // InsertChar's UTF-8 handling independent of key-event delivery.
    else if (a == "--mouse-after-frames") {
      std::string spec = next("--mouse-after-frames");
      auto colon = spec.find(':');
      mouseAfterFrames =
          colon == std::string::npos ? 0 : atoi(spec.substr(0, colon).c_str());
      if (mouseAfterFrames <= 0) {
        fprintf(stderr,
                "rn-impeller: --mouse-after-frames wants N:OP@X,Y;... with "
                "N > 0 (got %s)\n",
                spec.c_str());
        return 2;
      }
      std::string rest = spec.substr(colon + 1);
      size_t pos = 0;
      while (pos < rest.size()) {
        size_t semi = rest.find(';', pos);
        std::string seg = rest.substr(
            pos, semi == std::string::npos ? std::string::npos : semi - pos);
        if (!seg.empty()) {
          MouseSpec ms;
          auto at = seg.find('@');
          auto comma = seg.find(',', at == std::string::npos ? 0 : at);
          std::string op = seg.substr(0, at);
          // item 6: optional "+mod,mod" suffix (shift, ctrl, alt, meta) and
          // button-prefixed ops: r (right), m (middle), b4 (back), b5
          // (forward), l (left, explicit) -- e.g. rdown+ctrl,shift@X,Y.
          std::string modStr;
          if (auto plus = op.find('+'); plus != std::string::npos) {
            modStr = op.substr(plus + 1);
            op = op.substr(0, plus);
          }
          int button = -1;
          if (op.rfind("b4", 0) == 0) { button = 3; op = op.substr(2); }
          else if (op.rfind("b5", 0) == 0) { button = 4; op = op.substr(2); }
          else if (op == "rdown" || op == "rup") { button = 2; op = op.substr(1); }
          else if (op == "mdown" || op == "mup") { button = 1; op = op.substr(1); }
          else if (op == "ldown" || op == "lup") { button = 0; op = op.substr(1); }
          bool badMod = false;
          for (size_t mp = 0; mp < modStr.size();) {
            size_t mc = modStr.find(',', mp);
            const std::string md = modStr.substr(
                mp, mc == std::string::npos ? std::string::npos : mc - mp);
            if (md == "shift") ms.shift = true;
            else if (md == "ctrl") ms.ctrl = true;
            else if (md == "alt") ms.alt = true;
            else if (md == "meta") ms.meta = true;
            else if (!md.empty()) badMod = true;
            if (mc == std::string::npos) break;
            mp = mc + 1;
          }
          if (at == std::string::npos || comma == std::string::npos ||
              badMod ||
              (op != "down" && op != "up" && op != "move" && op != "sdown")) {
            fprintf(stderr,
                    "rn-impeller: --mouse-after-frames bad event '%s' (want "
                    "[r|m|l|b4|b5]down|up|move|sdown[+mods]@X,Y)\n",
                    seg.c_str());
            return 2;
          }
          ms.op = op == "up" ? 1 : op == "move" ? 2 : 0;
          if (op == "sdown") ms.shift = true;
          // A modifier on a plain down/up routes through the full-modifier
          // path as an explicit left-button event.
          if (button < 0 && (ms.ctrl || ms.alt || ms.meta) && ms.op != 2)
            button = 0;
          ms.button = button;
          ms.x = atof(seg.substr(at + 1, comma - at - 1).c_str());
          ms.y = atof(seg.substr(comma + 1).c_str());
          mouseSequence.push_back(ms);
        }
        if (semi == std::string::npos) break;
        pos = semi + 1;
      }
    }
    else if (a == "--char-after-frames") {
      std::string spec = next("--char-after-frames");
      auto colon = spec.find(':');
      if (colon == std::string::npos) {
        fprintf(stderr,
                "rn-impeller: --char-after-frames wants N:CP[;CP...] "
                "(got %s)\n",
                spec.c_str());
        return 2;
      }
      charAfterFrames = atoi(spec.substr(0, colon).c_str());
      if (charAfterFrames <= 0) {
        fprintf(stderr,
                "rn-impeller: --char-after-frames needs N > 0 (got %s)\n",
                spec.c_str());
        return 2;
      }
      std::string rest = spec.substr(colon + 1);
      size_t pos = 0;
      while (pos < rest.size()) {
        size_t semi = rest.find(';', pos);
        std::string seg = rest.substr(
            pos, semi == std::string::npos ? std::string::npos : semi - pos);
        if (!seg.empty()) {
          CharSpec cs;
          if (seg.size() > 2 && (seg[0] == 'U' || seg[0] == 'u') &&
              seg[1] == '+') {
            cs.codepoint =
                (unsigned int)strtoul(seg.c_str() + 2, nullptr, 16);
          } else {
            cs.codepoint = (unsigned int)strtoul(seg.c_str(), nullptr, 10);
          }
          charSequence.push_back(cs);
        }
        if (semi == std::string::npos) break;
        pos = semi + 1;
      }
      if (charSequence.empty()) {
        fprintf(stderr,
                "rn-impeller: --char-after-frames needs at least one CP "
                "segment (got %s)\n",
                spec.c_str());
        return 2;
      }
    }
    else if (a == "--log-mutations") logMutations = true;
    else if (a == "--list-modules") listModules = true;
    else if (a == "--test-openurl") testOpenUrl = true;
    else if (a == "--test-pointscale") testPointScale = true;
    else if (a == "--test-caret-blink") testCaretBlink = true;
    // ENG-22: a dir of .ttf/.otf/.ttc files to register (repeatable; also
    // RNI_FONT_DIRS, colon-separated). Faces register under their own family.
    else if (a == "--font-dir") gFontDirs.push_back(next("--font-dir"));
    else if (a == "--title") gWindowTitle = next("--title");
    else if (a == "--test-urlparse") testUrlParse = true;
    else if (a == "--test-http") testHttp = true;
    else if (a == "--color-scheme") { colorScheme = next("--color-scheme"); colorSchemeGiven = true; }
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
    else if (a == "--image-cache-mb") {
      const double mb = atof(next("--image-cache-mb").c_str());
      if (mb < 0) {
        fprintf(stderr, "rn-impeller: --image-cache-mb must be >= 0\n");
        return 2;
      }
      rni::image::SetCacheBudget((int64_t)(mb * 1048576.0));
    }
    else if (a == "--sdf-aa") {
      std::string v = next("--sdf-aa");
      if (v != "on" && v != "off") {
        fprintf(stderr, "rn-impeller: --sdf-aa wants on|off (got %s)\n", v.c_str());
        return 2;
      }
      rni::contextflags::SetSdfAa(v == "on");
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
  // parity item 13. --bundle may be a Metro URL
  // (http://host:8081/index.bundle?platform=impeller&dev=true). The bundle is
  // fetched over the same transport as fetch() (NetworkingModule's
  // performRequest), and the URL itself becomes the script's source URL, so
  // SourceCode.scriptURL / getDevServer() report it: bundleLoadedFromServer
  // is true and HMR + symbolication know which server to talk to.
  const bool bundleIsUrl = bundlePath.rfind("http://", 0) == 0 ||
                           bundlePath.rfind("https://", 0) == 0;
  std::string bundle;
  if (bundleIsUrl) {
    const rni::ParsedUrl purl = rni::parseUrl(bundlePath);
    if (!purl.valid) {
      fprintf(stderr, "rn-impeller: FATAL: bad --bundle URL: %s\n",
              purl.error.c_str());
      return 1;
    }
    printf("rn-impeller: bundle_fetch url=%s\n", bundlePath.c_str());
    fflush(stdout);
    // Metro builds the bundle on first request: allow it time.
    const rni::HttpResponse res =
        rni::performRequest("GET", purl, {{"Accept", "*/*"}}, "", 120000.0);
    if (!res.ok || res.status != 200) {
      fprintf(stderr,
              "rn-impeller: FATAL: cannot fetch bundle from %s (status %d%s%s)\n",
              bundlePath.c_str(), res.status, res.error.empty() ? "" : ": ",
              res.error.c_str());
      return 1;
    }
    bundle = res.body;
  } else {
    if (!IsAbsolute(bundlePath)) {
      fprintf(stderr,
              "rn-impeller: FATAL: --bundle must be an ABSOLUTE path or an "
              "http:// URL (no CWD fallback exists)\n");
      return 1;
    }
    if (!ReadFile(bundlePath, &bundle)) {
      fprintf(stderr, "rn-impeller: FATAL: cannot read bundle at %s\n",
              bundlePath.c_str());
      return 1;
    }
  }
  const std::string sourceUrl =
      bundleIsUrl ? bundlePath : "file://" + bundlePath;
  const bool shimOk = bundle.find(kShimMarker) != std::string::npos;
  const size_t bundleSize = bundle.size();  // captured before the move below
  // SC-23: with no --color-scheme the host follows the OS (windowed) or the
  // test hook (any mode); the flag and Appearance.setColorScheme override it.
  if (!colorSchemeGiven) {
    const std::string os = rni::ResolveSystemScheme(windowMode);
    if (!os.empty()) colorScheme = os;
    gFollowOsAppearance = windowMode;
  }
  printf("rn-impeller: color_scheme=%s source=%s\n", colorScheme.c_str(),
         colorSchemeGiven ? "flag" : (rni::OsAppearanceHookActive() ? "hook" : (windowMode ? "os" : "default")));
  printf("rn-impeller: app=%s\n", appName.c_str());
  printf("rn-impeller: bundle=%s (%zu bytes)\n", bundlePath.c_str(), bundle.size());
  printf("rn-impeller: shim_marker=%s\n", shimOk ? "PRESENT" : "MISSING");
  printf("rn-impeller: headless=%s\n", headless ? "yes" : "no");
#if defined(_WIN32)
  printf("rn-impeller: platform=win32\n");  // SC-40: gates assert which engine ran
#elif defined(__APPLE__)
  printf("rn-impeller: platform=darwin\n");
#elif defined(__ANDROID__)
  printf("rn-impeller: platform=android\n");
#else
  printf("rn-impeller: platform=linux\n");
#endif
  fflush(stdout);

  if (windowMode) {
#if RNI_WITH_WINDOW
    // P12-01: --idle-skip defaults ON in windowed mode (real display => a clean
    // frame should SLEEP, not spin a core). An explicit --idle-skip/--no-idle-skip
    // wins; a bounded --frames run or the mutation-verify --idle-mutant paths set
    // it explicitly, so this only flips the interactive default. The loop's own
    // handsPending guard keeps every frame-anchored windowed gate (resize/click/
    // scroll/hover/stall/screenshot/--frames) painting on schedule regardless.
    if (!idleSkipSet && frames == 0) idleSkip = true;
    // FP-11: a bounded --frames N run is a test run: frame-anchored hooks plus
    // --screenshot-after deadlines in ms calibrated on the unpaced loop. Keep
    // its pre-FP-11 timing unless --vsync asks otherwise.
    if (!gVsyncSet && frames > 0) gVsyncSource = rni::FrameScheduler::Source::kPlatform;
    gWindowedTypeSpec = typeSpec;  // ENG-18
    return RunWindowed(sourceUrl, appName, std::move(bundle), 0, bundleSize,
                       colorScheme, initialUrl,
                       widthGiven ? width : 0, heightGiven ? height : 0,
                       pointScale,
                       logMutations, frames, screenshotAfterMs, screenshot,
                       screenshotFirst, pointScaleGiven, resizeAfterFrames,
                       resizeToW, resizeToH, stallAfterFrames, stallMs,
                       clickAfterFrames, clickX, clickY,
                       scrollAfterFrames, scrollX, scrollY, scrollDx, scrollDy,
                       hoverAfterFrames, hoverPoints, hoverLeaveAtEnd,
                       keyAfterFrames, keySequence,
                       charAfterFrames, charSequence,
                       mouseAfterFrames, mouseSequence,
                       supersampleRnsvg,
                       idleSkip, idleRunSec, idleBudgetMs, idleLog, idleMutant,
                       idleOffthreadAfter);
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
  // ENG-22: app fonts before the first measure (FabricHost is built below).
  rni::RegisterFontDirs(surface.typography(), rni::FontDirsFrom(gFontDirs));
  // A degraded surface (main FBO unavailable under GPU pressure, or
  // RNI_FORCE_FBO_FAIL) mounts and walks the tree for counts but has no
  // drawable. Every pixel-dependent step below is gated on this; the run still
  // exits 0 with scene_nodes / painted_nodes / node_frame, which is the whole
  // proof a count-only gate needs.
  const bool havePixels = surface.hasDrawSurface();

  int painted = 0;
  size_t nodeCount = 0;
  {
    rni::SceneGraph sceneGraph(surface.typography());
    // ENG item 2 — same wiring as the primary headless path above.
    sceneGraph.setRenderContext(surface.context());
    sceneGraph.setSupersample(supersampleRnsvg);
    // ENG item 2b — root supersample offscreen size, device pixels.
    sceneGraph.setSurfaceSize(width, height);
    // parity item 24: a Metro-served bundle is debuggable.
    rni::ReactHost host(/*withInspector*/ sourceUrl.rfind("http://", 0) == 0);
    host.setKnownComponents(rni::FabricHost::knownComponentNames());
    // ENG-09 — wire the world raster store, same as the primary path.
    sceneGraph.setWorldRasterStore(host.worldRasterStore());
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
    // FP-40: headless LayoutAnimation time is frame-counted (16.667 ms per
    // stepped frame), like the NativeAnimated clock, so captures are repeatable.
    // Declared before fabric: the KFM keeps the clock until fabric dies.
    std::atomic<uint64_t> layoutAnimFrames{0};
    rni::FabricHost fabric(host.instance(), &sceneGraph, surface.typography(),
                           logMutations, host.displayMetrics());
    fabric.setLayoutAnimationClock([&layoutAnimFrames]() -> uint64_t {
      return layoutAnimFrames.load() * 16667 / 1000;
    });

    host.setReloadHook([](const std::string& reason) { ReexecForReload(reason); });
    host.runScript(std::move(bundle), sourceUrl);
    host.devServerSetup(sourceUrl);  // parity item 14 (no-op for file://)
    host.connectInspector(sourceUrl, appName);  // parity item 24
    // Let the bundle finish evaluating (AppRegistry.registerComponent) before
    // asking for the surface, otherwise runApplication names a module that is
    // not registered yet.
    host.waitForJsIdle(10000);

    fabric.startSurface(appName, 1, (float)width, (float)height, pointScale);
    // React renders, Fabric commits, the delegate applies mutations — all on
    // the JS thread. Idle means that whole chain has drained.
    host.waitForJsIdle(10000);
    // FP-16: <Image> decodes run on the IO pool, off the JS thread, so an idle
    // JS thread does not mean the pixels exist. Drain them, then the JS their
    // load events scheduled (which may mount more images).
    for (int i = 0; i < 4 && rni::image::WaitIdle(15000); ++i) host.waitForJsIdle(10000);

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
      for (int i = 0; i < 4 && rni::image::WaitIdle(15000); ++i) host.waitForJsIdle(10000);
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
      // P1 item 15: the SAME press-path the windowed mouse handler runs, so a
      // headless drag across a <Text selectable> selects exactly as a real
      // one does (the Mac audit's probe://select scene drives this).
      fabric.beginTextSelection(pts.front().first, pts.front().second);
      // Every intermediate point is a held move; the LAST point is the release.
      // Report the tag each move reached: it MUST equal downTag for the whole
      // drag, including a waypoint outside the control's bounds.
      int lastMoveTag = downTag;
      for (size_t i = 1; i + 1 < pts.size(); ++i) {
        // P1 item 15: the windowed hover handler extends a held selection
        // FIRST (dragTextSelection), then routes the captured move; mirror it.
        fabric.dragTextSelection(pts[i].first, pts[i].second);
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
        fabric.dragTextSelection(pts.back().first, pts.back().second);
        int mt = fabric.dispatchCapturedMove(pts.back().first, pts.back().second);
        lastMoveTag = mt;
        printf("rn-impeller: drag_move_tag=%d at=%.1f,%.1f\n", mt,
               pts.back().first, pts.back().second);
      } else {
        // A real pointer reaches the release point through a cursor move
        // first; extend a held text selection to it the same way.
        fabric.dragTextSelection(pts.back().first, pts.back().second);
      }
      int upTag = fabric.endTouchCapture(pts.back().first, pts.back().second);
      fabric.endTextSelectionDrag();  // the windowed release does the same
      printf("rn-impeller: drag_up_tag=%d at=%.1f,%.1f\n", upTag,
             pts.back().first, pts.back().second);
      // P1 item 15: RNI_DRAG_COPY=1 presses the platform Copy chord after the
      // release, through dispatchKeyEvent (the real key path), so a gate can
      // prove a selectable <Text>'s selection reaches the clipboard.
      if (const char* dc = std::getenv("RNI_DRAG_COPY"); dc && dc[0] == '1') {
        rni::FabricHost::KeyModifiers cm{};
#if defined(__APPLE__)
        cm.meta = true;
#else
        cm.ctrl = true;
#endif
        fabric.dispatchKeyEvent("c", "KeyC", rni::FabricHost::KeyEventPhase::Down, cm);
      }
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
      // ENG-18: the same token list the windowed --type hook consumes.
      // ENG-24: Enter / Shift+Enter / Backspace also send the key event a
      // real key does first (onKeyPress, keyDown), then the edit, then the
      // release -- the order GlfwSurface::dispatchKeyEvent runs them in.
      auto keyEvent = [&](const char* key, bool shift,
                          rni::FabricHost::KeyEventPhase phase) {
        rni::FabricHost::KeyModifiers mods;
        mods.shift = shift;
        fabric.dispatchKeyEvent(key, key, phase, mods);
      };
      for (const TypeToken& tk : ParseTypeSeq(seq)) {
        const bool keyed = tk.kind == TypeToken::Backspace ||
                           tk.kind == TypeToken::Enter ||
                           tk.kind == TypeToken::ShiftEnter;
        const char* keyName =
            tk.kind == TypeToken::Backspace ? "Backspace" : "Enter";
        const bool keyShift = tk.kind == TypeToken::ShiftEnter;
        if (keyed) {
          keyEvent(keyName, keyShift, rni::FabricHost::KeyEventPhase::Down);
        }
        switch (tk.kind) {
          case TypeToken::Backspace:
            fabric.dispatchKey(rni::FabricHost::KeyAction::Backspace, 0);
            break;
          case TypeToken::Enter:
            fabric.dispatchKey(rni::FabricHost::KeyAction::Submit, 0);
            break;
          case TypeToken::ShiftEnter:
            fabric.dispatchKey(rni::FabricHost::KeyAction::Newline, 0);
            break;
          case TypeToken::SelectAll:
            // Style audit item 11 gate: select all, then <COPY>/<CUT>, so a
            // headless run can prove a secure field refuses the clipboard.
            fabric.dispatchKey(rni::FabricHost::KeyAction::SelectAll, 0);
            break;
          case TypeToken::Copy:
            fabric.dispatchKey(rni::FabricHost::KeyAction::Copy, 0);
            break;
          case TypeToken::Cut:
            fabric.dispatchKey(rni::FabricHost::KeyAction::Cut, 0);
            break;
          case TypeToken::Char:
            fabric.dispatchKey(rni::FabricHost::KeyAction::InsertChar,
                               tk.codepoint);
            break;
        }
        if (keyed) {
          keyEvent(keyName, keyShift, rni::FabricHost::KeyEventPhase::Up);
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
             focused, v.size(), caret, EscapeNewlines(v).c_str());
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
    // FP-01: headless frames have no swap; "present" is the stamp after the
    // draw into the offscreen target returns.
    rni::FrameTimings headlessTimings;
    int headlessPresents = 0;
    if (frames > 0) {
      // Per-frame JS-work baseline, taken after boot settled: everything
      // counted from here on happened DURING the stepped frames.
      const unsigned long loopTimers0 = host.jsTimersFired();
      const unsigned long loopMountTx0 = sceneGraph.mountTransactions();
      const unsigned long loopTicks0 = host.nativeAnimatedTicks();
      const unsigned long long loopTickUs0 = host.nativeAnimatedTickMicros();
      for (int frameIndex = 1; frameIndex <= frames; ++frameIndex) {
        // One NativeAnimated step, run on this thread (FP-10). The idle wait
        // still drains what it posts to JS (onEnd, layout-prop commits).
        auto hf = std::make_unique<rni::FrameTimingsRecorder>();
        hf->RecordVsync();
        hf->RecordBuildStart();
        layoutAnimFrames.fetch_add(1);
        fabric.tickLayoutAnimations();  // FP-40
        host.pumpNativeAnimated();
        host.waitForJsIdle(5000);
        // FP-33: decodes finish off-thread. Their load events are queued to JS before WaitIdle
        // returns, so the NEXT frame's waitForJsIdle mounts what they trigger, and every frame
        // paints the images its predecessor's events mounted (and reloads of purged images).
        rni::image::WaitIdle(5000);

        TRACE_EVENT0("frame", "Frame");
        ImpellerDisplayListBuilder fb = ImpellerDisplayListBuilderNew(nullptr);
        {
          TRACE_EVENT0("paint", "PaintWalk");
          sceneGraph.paint(fb, pointScale);
        }
        ImpellerDisplayList fdl;
        {
          TRACE_EVENT0("paint", "DisplayListBuild");
          fdl = ImpellerDisplayListBuilderCreateDisplayListNew(fb);
        }
        hf->RecordBuildEnd();
        hf->RecordRasterStart();
        if (fdl != nullptr) {
          TRACE_EVENT0("raster", "Draw");
          surface.drawDisplayList(fdl);
          ImpellerDisplayListRelease(fdl);
        }
        ImpellerDisplayListBuilderRelease(fb);
        hf->RecordRasterEnd();
        {
          // Headless has no swap; the readback below is its present.
          TRACE_EVENT0("raster", "Present");
          hf->RecordPresent();
        }
        ++headlessPresents;
        rni::glvalidation::OnFrame();  // FP-05 test hook
        hf->SetImageCacheBytes(rni::image::CacheBytes());  // FP-33
        headlessTimings.Commit(std::move(hf));
        rni::image::OnFrame();  // FP-33 test hook

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
      // Cost of an animation DURING the stepped frames, per the Mac's ask
      // (DS-INPUT-SPIN item 4). js_timers = JS timer callbacks run (rAF is a
      // setTimeout(0) here, so a JS-driven Animated loop shows ~1 per frame);
      // mount_tx = React commits that reached the scene (a JS-driven loop
      // commits every frame). Both stay 0 for a native-driven loop.
      // tick_us = time inside RN's C++ onRender, on the frame-loop thread
      // since FP-10; it executes no JS.
      const unsigned long loopTicks = host.nativeAnimatedTicks() - loopTicks0;
      const unsigned long long loopTickUs =
          host.nativeAnimatedTickMicros() - loopTickUs0;
      printf("rn-impeller: frameloop frames=%d js_timers=%lu mount_tx=%lu "
             "nativeanimated_ticks=%lu tick_us_total=%llu tick_us_avg=%.1f\n",
             frames, host.jsTimersFired() - loopTimers0,
             sceneGraph.mountTransactions() - loopMountTx0, loopTicks,
             loopTickUs, loopTicks ? (double)loopTickUs / loopTicks : 0.0);
      fflush(stdout);
    }

    auto finalFrame = std::make_unique<rni::FrameTimingsRecorder>();
    finalFrame->RecordVsync();
    finalFrame->RecordBuildStart();
    ImpellerDisplayListBuilder builder = ImpellerDisplayListBuilderNew(nullptr);
    painted = sceneGraph.paint(builder, pointScale);
    // ENG-10: GPU sprite quads actually issued this paint (gate arm).
    printf("rn-impeller: world_sprites_drawn=%d\n",
           sceneGraph.worldSpritesDrawn());
    if (probeBanner) {
      DrawProbeBanner(builder, shimOk, bundleSize, width, height);
    }
    // Degraded (no drawable): the paint walk above already produced `painted`
    // and the node_frame report, which is the count-only proof. Skip the draw
    // and readback — there is no surface to draw into. Do NOT abort.
    if (havePixels) {
      ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(builder);
      finalFrame->RecordBuildEnd();
      finalFrame->RecordRasterStart();
      if (dl == nullptr) {
        fprintf(stderr, "rn-impeller: FATAL: CreateDisplayListNew returned null\n");
        return 1;
      }
      if (!surface.drawDisplayList(dl)) {
        fprintf(stderr, "rn-impeller: FATAL: SurfaceDrawDisplayList failed\n");
        return 1;
      }
      ImpellerDisplayListRelease(dl);
      finalFrame->RecordRasterEnd();
      finalFrame->RecordPresent();
      finalFrame->SetImageCacheBytes(rni::image::CacheBytes());  // FP-33
      ++headlessPresents;
      headlessTimings.Commit(std::move(finalFrame));
    } else {
      headlessTimings.Discard(std::move(finalFrame));
    }
    ImpellerDisplayListBuilderRelease(builder);
    printf("rn-impeller: presents=%d\n", headlessPresents);
    fabric.printLayoutAnimationSummary();  // FP-40
    FinishFrameTimings(headlessTimings);
    FinishTrace();
    rni::glvalidation::Finish();
    rni::image::PrintStats();  // FP-16
    rni::typography::PrintSummary();  // FP-12
  }

  std::vector<rni::Px> px;
  if (havePixels && !surface.readPixels(&px)) {
    fprintf(stderr, "rn-impeller: FATAL: glReadPixels failed\n");
    return 1;
  }
  auto at = [&](int x, int y) -> rni::Px { return px[(size_t)y * width + x]; };

  printf("rn-impeller: painted_nodes=%d\n", painted);
  // Degraded run: no pixels were captured, so every pixel-derived line below is
  // meaningless (and `at()` would index an empty buffer). painted_nodes and the
  // node_frame report above are the count-only proof; emit the degraded marker
  // and finish clean with exit 0.
  if (!havePixels) {
    printf("rn-impeller: degraded_no_pixels=1\n");
    if (!shimOk) {
      printf("RN_IMPELLER_FAIL (packaging shim marker absent from bundle)\n");
      return 4;
    }
    printf("RN_IMPELLER_RENDER_OK app=%s\n", appName.c_str());
    fflush(stdout);
    return 0;
  }
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
