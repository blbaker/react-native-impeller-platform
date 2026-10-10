#pragma once
// SC-16: ellipsizeMode head and middle. Impeller's ellipsis setter is tail-only,
// so a single-line head/middle paragraph is truncated by hand to the widest text
// that fits.
#include <functional>
#include <vector>

#include "SceneGraph.h"

namespace rni {

// Widest-fit text of `runs` joined, with U+2026 at the start (mode 1, Head) or
// the middle (mode 3, Middle). `widthOf` shapes the runs in one unbounded line
// with the paint style. Returns `runs` unchanged when they already fit in `w`.
std::vector<TextRun> EllipsizeRuns(const std::vector<TextRun>& runs, int mode, float w,
                                   const std::function<float(const std::vector<TextRun>&)>& widthOf);

}  // namespace rni
