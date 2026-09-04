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
  if (failures) {
    printf("POINTSCALE_SELFTEST_FAIL failures=%d\n", failures);
    return 1;
  }
  printf("POINTSCALE_SELFTEST_OK cases=%d\n", (int)(sizeof(cases) / sizeof(cases[0])));
  return 0;
}

}  // namespace rni
