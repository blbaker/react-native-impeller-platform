#pragma once

// FP-34: counts glLinkProgram calls per phase (context creation, pre-warm tour, after the first
// present). A shader program linked after the first present is a first-use compile on the frame
// path; the pre-warm tour exists to make that number zero. Installed by wrapping the GL proc loader.

#include <cstdint>

namespace rni::programcount {

enum class Phase : int { kStartup = 0, kTour = 1, kFrames = 2 };

// Proc loader hook: returns a counting wrapper for glLinkProgram, `real` for every other name.
void* Wrap(const char* name, void* real);

// Programs linked from now on count against `phase` (any thread).
void SetPhase(Phase phase);

uint64_t Linked(Phase phase);

// `rn-impeller: programs startup=N tour=N frames=N` (frames = linked after the first present).
void PrintSummary();

}  // namespace rni::programcount
