// PointScale — the ONE place that decides how many device pixels a point is
// worth on the windowed path.
//
// ⛔ WHY THIS IS A SEPARATE, PURE FUNCTION.
// The windowed path has two different unit systems arriving at the same
// variables, and the bug this file exists to prevent was invisible in both of
// them individually:
//
//   * glfwCreateWindow(width, height) takes SCREEN COORDINATES (points).
//   * glfwGetFramebufferSize() reports PIXELS.
//
// On a 1x display those are equal, so every gate on a 1x host passes whether
// the code is right or wrong. On a 2x display (Retina) a 1280x860 request
// yields a 2560x1720 pixel framebuffer, and passing the ORIGINAL numbers to
// displayMetrics/startSurface/paint lays the app out in 1280x860 points and
// rasterises at 1x — 1280x860 real pixels of content sitting in the top-left
// corner of a 2560x1720 framebuffer, with the remainder never painted.
//
// That failure does NOT look like a layout bug on screen. macOS does not
// upscale it; the engine simply under-renders, so glyphs are rasterised for a
// 1x display and then presented one engine pixel per physical pixel. The
// symptom is "thin, half-size, pixelated next to a real AppKit window", which
// reads like a font problem and is not one.
//
// Keeping the decision in a pure function means it can be gated WITHOUT a
// Retina display: tools/ci-pointscale.sh feeds it the exact number pairs a 2x
// Mac produces and asserts the answer, on a 1x Linux CI host.
#pragma once

#include <cmath>
#include <cstdio>

namespace rni {

// Device pixels per point for a window, derived from the two sizes GLFW
// reports for it.
//
//   fbSize   — glfwGetFramebufferSize, in PIXELS
//   winSize  — glfwGetWindowSize, in SCREEN COORDINATES (points)
//   cliScale / cliScaleGiven — an explicit --scale on the command line
//
// ⛔ --scale IS AN OVERRIDE, NOT THE SOURCE OF TRUTH (windowed path only).
// Defaulting it to 1.0 and treating that default as an answer is precisely
// the bug above: 1.0 is indistinguishable from "the display really is 1x".
// The display is the source of truth; --scale exists to force a value when
// testing, and an explicit one still wins so the retina gates that pass
// --scale 2 keep meaning what they meant. The HEADLESS path is unaffected —
// it has no window and no backing scale, so --scale remains its only input.
inline float DeriveWindowPointScale(int fbSize, int winSize, float cliScale,
                                    bool cliScaleGiven) {
  if (cliScaleGiven && cliScale > 0.0f) return cliScale;
  // A degenerate report (minimised window, headless X, a GLFW backend that
  // does not implement one of the two queries) must not produce 0 or inf and
  // silently divide the surface to nothing. Falling back to 1.0 reproduces
  // the pre-existing behaviour exactly, which is the safe direction.
  if (fbSize <= 0 || winSize <= 0) return 1.0f;
  const float ratio = (float)fbSize / (float)winSize;
  if (!std::isfinite(ratio) || ratio <= 0.0f) return 1.0f;
  return ratio;
}

// ⛔ A CURSOR POSITION IS NOT A LAYOUT COORDINATE. THIS IS THE CONVERSION.
//
// glfwGetCursorPos and the cursor-position callback both report SCREEN
// COORDINATES (points, the same unit glfwGetWindowSize speaks) — NOT device
// pixels, and NOT this engine's layout points. FabricHost::dispatchTouch wants
// layout points, which are `framebufferPixels / pointScale`.
//
// Those three units collapse into one on a 1x display, which is why a wrong
// conversion here passes every gate on this Linux host and lands on the WRONG
// ELEMENT on a Retina Mac. They collapse into TWO on a normal Retina window,
// where pointScale is derived from fb/win and layout points therefore equal
// screen coordinates exactly — making the identity conversion look correct
// right up until someone passes `--scale`.
//
// The general form, which is identity in both of those cases and right in the
// third:
//
//     pixels       = cursorScreen * (fbSize / winSize)      // real device ratio
//     layoutPoints = pixels / pointScale                    // effective scale
//
// With no --scale, pointScale IS fbSize/winSize, so the two factors cancel and
// this returns cursorScreen unchanged. With `--scale 2` on a 1x display the
// layout is half the framebuffer in each axis, and a click at screen 300 must
// arrive as 150 — not 300, which would hit-test past the end of the surface,
// and not 600, which is the classic factor-of-two.
//
// Pure and header-only for the same reason DeriveWindowPointScale is: it can
// then be gated on a host with no Retina display and no mouse.
inline float CursorPointsFromScreen(double cursorScreen, int fbSize,
                                    int winSize, float pointScale) {
  if (fbSize <= 0 || winSize <= 0 || !(pointScale > 0.0f))
    return (float)cursorScreen;
  const double deviceRatio = (double)fbSize / (double)winSize;
  if (!std::isfinite(deviceRatio) || deviceRatio <= 0.0) return (float)cursorScreen;
  const double points = cursorScreen * deviceRatio / (double)pointScale;
  if (!std::isfinite(points)) return (float)cursorScreen;
  return (float)points;
}

// Exercises DeriveWindowPointScale over the real number pairs each platform
// produces, printing one line per case. Lets a 1x host gate the 2x answer.
// Returns 0 when every case matches.
inline int runPointScaleSelfTest() {
  struct Case {
    const char* name;
    int fb;
    int win;
    float cli;
    bool given;
    float expect;
  };
  const Case cases[] = {
      // The defect, as measured on Baker's Retina Mac: a 1280-point window
      // backed by a 2560-pixel framebuffer must yield 2.0, not the 1.0 the
      // old default produced.
      {"retina 2x window", 2560, 1280, 1.0f, false, 2.0f},
      {"retina 2x tall", 1720, 860, 1.0f, false, 2.0f},
      // The 1x case must be BYTE-IDENTICAL to the old behaviour, which is the
      // whole reason every existing Linux gate is allowed to keep its golden.
      {"1x window", 1280, 1280, 1.0f, false, 1.0f},
      {"1x odd size", 1013, 1013, 1.0f, false, 1.0f},
      // Fractional backing scales are real (125%/150% Windows, some Linux
      // compositors). Nothing may round them to an integer.
      {"1.5x window", 1920, 1280, 1.0f, false, 1.5f},
      // An explicit --scale still wins, so tools/retina-check.sh's
      // `--scale 2` keeps its meaning.
      {"explicit --scale 2 overrides a 1x window", 800, 800, 2.0f, true, 2.0f},
      {"explicit --scale 1 overrides a 2x window", 2560, 1280, 1.0f, true, 1.0f},
      {"explicit --scale 3", 900, 900, 3.0f, true, 3.0f},
      // Degenerate reports fall back to the old default rather than dividing
      // the surface by zero.
      {"minimised window (0 fb)", 0, 1280, 1.0f, false, 1.0f},
      {"zero window size", 2560, 0, 1.0f, false, 1.0f},
      {"both zero", 0, 0, 1.0f, false, 1.0f},
      {"negative report", -1, -1, 1.0f, false, 1.0f},
  };
  int failures = 0;
  for (const Case& c : cases) {
    const float got = DeriveWindowPointScale(c.fb, c.win, c.cli, c.given);
    const bool ok = std::fabs(got - c.expect) < 1e-6f;
    if (!ok) ++failures;
    printf("  %-42s fb=%-5d win=%-5d cli=%.2f%s -> %.4f (want %.4f) %s\n",
           c.name, c.fb, c.win, c.cli, c.given ? " [given]" : "        ", got,
           c.expect, ok ? "ok" : "MISMATCH");
  }

  // ⛔ THE CURSOR CONVERSION IS GATED HERE, ON A 1x HOST WITH NO MOUSE.
  // A factor-of-two error in CursorPointsFromScreen does not crash and does
  // not log — it silently hits the WRONG ELEMENT, or nothing, on a Retina
  // display only. That is unobservable on this CI host by any means except
  // feeding the function the number pairs a 2x Mac produces, which is exactly
  // what these cases are.
  struct CursorCase {
    const char* name;
    double cursor;
    int fb;
    int win;
    float scale;
    float expect;
  };
  const CursorCase cursorCases[] = {
      // 1x, no override: identity. Every existing Linux input gate lives here,
      // so this case is what says the change is a no-op for them.
      {"1x window, cursor 200", 200.0, 800, 800, 1.0f, 200.0f},
      // Retina, scale derived from the window: fb/win and pointScale are the
      // SAME 2.0 and cancel. A click at screen point 200 is layout point 200,
      // NOT 400 (the factor-of-two that hits the wrong element) and NOT 100.
      {"retina 2x derived, cursor 200", 200.0, 1600, 800, 2.0f, 200.0f},
      {"retina 2x derived, cursor 0", 0.0, 1600, 800, 2.0f, 0.0f},
      // --scale override on a 1x display: the layout is HALF the framebuffer,
      // so a click at 300 must arrive as 150. This is the case where treating
      // the cursor as already-in-points is wrong, and it is precisely the
      // configuration the macOS tester ran the resize gate under (--scale 2).
      {"--scale 2 on a 1x display, cursor 300", 300.0, 800, 800, 2.0f, 150.0f},
      // --scale 1 forced on a Retina window: layout points equal PIXELS, so a
      // screen-coordinate click must DOUBLE.
      {"--scale 1 forced on a 2x window, cursor 200", 200.0, 1600, 800, 1.0f,
       400.0f},
      // Fractional backing scale, derived: cancels like the 2x case.
      {"1.5x derived, cursor 640", 640.0, 1920, 1280, 1.5f, 640.0f},
      // ⛔ THE DARWIN CASE THE CI GATE USED TO GET WRONG.
      // `--scale 2` on a REAL Retina window: fb/win is ALSO 2, so the override
      // agrees with the derivation and the factors cancel — a screen click at
      // 200 is layout point 200, NOT 100. The 100 answer is correct only on a
      // 1x host, where fb/win is 1. the macOS tester's darwin-arm64 run failed
      // an assertion that hardcoded the 1x answer against this correct code;
      // pinning both hosts' numbers here is what keeps that from recurring.
      {"--scale 2 on a Retina window (darwin), cursor 200", 200.0, 800, 400,
       2.0f, 200.0f},
      {"--scale 2 on a 1x window (linux CI), cursor 200", 200.0, 400, 400, 2.0f,
       100.0f},
      // Same window, --scale 4: the divisor doubles, the answer halves. This
      // pair is the ratio the gate's assertion D2 checks by clicking, and it
      // holds on every display because fb/win is common to both.
      {"--scale 4 on a Retina window (darwin), cursor 200", 200.0, 800, 400,
       4.0f, 100.0f},
      {"--scale 4 on a 1x window (linux CI), cursor 200", 200.0, 400, 400, 4.0f,
       50.0f},
      // Degenerate reports must pass the cursor through unchanged rather than
      // divide by zero and dispatch a NaN into the hit test.
      {"minimised window (0 fb)", 200.0, 0, 800, 1.0f, 200.0f},
      {"zero window size", 200.0, 800, 0, 1.0f, 200.0f},
      {"zero scale", 200.0, 800, 800, 0.0f, 200.0f},
  };
  for (const CursorCase& c : cursorCases) {
    const float got = CursorPointsFromScreen(c.cursor, c.fb, c.win, c.scale);
    const bool ok = std::fabs(got - c.expect) < 1e-4f;
    if (!ok) ++failures;
    printf("  %-44s cur=%-7.1f fb=%-5d win=%-5d scale=%.2f -> %.4f (want %.4f) %s\n",
           c.name, c.cursor, c.fb, c.win, c.scale, got, c.expect,
           ok ? "ok" : "MISMATCH");
  }

  if (failures) {
    printf("POINTSCALE_SELFTEST_FAIL failures=%d\n", failures);
    return 1;
  }
  printf("CURSORPOINTS_SELFTEST_OK cases=%d\n",
         (int)(sizeof(cursorCases) / sizeof(cursorCases[0])));
  printf("POINTSCALE_SELFTEST_OK cases=%d\n", (int)(sizeof(cases) / sizeof(cases[0])));
  return 0;
}

}  // namespace rni
