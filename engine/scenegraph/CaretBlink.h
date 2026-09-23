// <TextInput>. ENG-01b item 5: caret blink.
//
// The caret is a blinking bar: on for ~500 ms, off for ~500 ms, and it must
// become VISIBLE AGAIN on every keystroke so a burst of typing never hides the
// insertion point behind an off phase. That "reset to visible on edit" is the
// half a naive `blink = (now/500) % 2` gets wrong — with a free-running clock
// the caret can be mid-off-phase exactly when the user types, so the character
// lands next to an invisible caret.
//
// ⛔ THE BLINK DECISION IS PURE, AND THAT IS WHY IT IS TESTABLE AT ALL.
// Whether the caret paints this frame is a function of ONE input: milliseconds
// since the last caret reset (a keystroke, a focus, a click into the field).
// The wall clock, the frame loop and Impeller are not involved in the DECISION
// — they only supply that one number and draw the result. Factoring the rule
// out here lets --test-caret-blink gate it on a host with no window and no
// clock skew, the same way runPointScaleSelfTest gates the Retina scale and
// runOpenUrlSelfTest gates the URL predicate: the logic whose wrong answer is
// invisible on this CI host is exercised directly instead of inferred from a
// screenshot that happened to catch an on phase.
#pragma once

#include <cstdint>
#include <cstdio>

namespace rni {

// The blink half-period. The caret is visible for the first `periodMs` after a
// reset, hidden for the next `periodMs`, and so on. ~500 ms is the platform
// convention (macOS NSTextInsertionPointBlinkPeriod, Windows caret blink time).
inline constexpr int kCaretBlinkPeriodMs = 500;

// Is the caret painted `msSinceReset` milliseconds after the last reset?
//
// ⛔ msSinceReset == 0 MUST BE VISIBLE. That is the "just typed" instant, and a
// caret that blinks off the moment a key is pressed is the exact bug this
// function exists to prevent. So phase 0 (the first half-period after any
// reset) is ON, phase 1 is OFF, phase 2 ON, ... — an EVEN phase is visible.
// A negative input (a clock that ran backwards, which std::chrono can under NTP
// steps) is clamped to the visible phase rather than allowed to index a
// negative bucket.
inline bool caretVisible(long long msSinceReset, int periodMs = kCaretBlinkPeriodMs) {
  if (periodMs <= 0) return true;         // no blink configured -> solid caret
  if (msSinceReset < 0) return true;      // pre-reset / clock skew -> visible
  const long long phase = msSinceReset / periodMs;
  return (phase % 2) == 0;                // even phase on, odd off
}

// Exercises caretVisible over the boundary cases a screenshot cannot reliably
// hit (the exact ms a phase flips, the just-typed instant, a backward clock).
// Prints one line per case; returns 0 when every case matches. This is what
// --test-caret-blink runs.
inline int runCaretBlinkSelfTest() {
  struct Case {
    const char* name;
    long long ms;
    int period;
    bool expect;
  };
  const Case cases[] = {
      // The load-bearing one: the instant a key is pressed, the caret is ON.
      {"just typed (t=0)", 0, 500, true},
      {"mid first on-phase", 250, 500, true},
      {"last ms of on-phase", 499, 500, true},
      {"first ms of off-phase", 500, 500, false},
      {"mid off-phase", 750, 500, false},
      {"back on after a full period", 1000, 500, true},
      {"off again", 1500, 500, false},
      {"on again", 2000, 500, true},
      // A backward clock (NTP step, suspend/resume) must not hide the caret.
      {"negative (clock skew) -> visible", -50, 500, true},
      // periodMs <= 0 disables blink: a solid caret, never hidden.
      {"period 0 disables blink", 999999, 0, true},
      {"period negative disables blink", 250, -1, true},
  };
  int failures = 0;
  for (const Case& c : cases) {
    const bool got = caretVisible(c.ms, c.period);
    const bool ok = got == c.expect;
    if (!ok) ++failures;
    std::printf("  %-38s ms=%-7lld period=%-4d -> %s (want %s) %s\n", c.name,
                c.ms, c.period, got ? "on" : "off", c.expect ? "on" : "off",
                ok ? "ok" : "MISMATCH");
  }
  std::printf("caret-blink self-test: %s (%d failure%s)\n",
              failures == 0 ? "PASS" : "FAIL", failures,
              failures == 1 ? "" : "s");
  return failures == 0 ? 0 : 1;
}

}  // namespace rni
