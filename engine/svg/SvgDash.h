// SvgDash — ENG-13: strokeDasharray / strokeDashoffset for RNSVG shapes.
//
// Impeller's C API has no dash path effect (only DrawDashedLine, one straight
// segment at phase 0), so the dashes are cut here: the shape's `d` is parsed
// through the SAME parser the fill uses (svg/SvgPath), each segment is
// measured by arc length, and every "on" interval is emitted as its own open
// subpath. Curves stay curves: a dash on a cubic is the exact sub-cubic
// (de Casteljau split), not a polyline. The stroke paint then strokes that
// path, so caps and joins apply per dash exactly as SVG specifies.
//
// Rules followed (SVG 2 "stroke-dasharray", Skia SkDashPath where SVG is
// silent, since Chrome and Android render with it):
//   - odd count: the list is repeated to make it even ("5 3 2" = "5 3 2 5 3 2")
//   - any negative value, or a sum of zero: no dashing (solid stroke)
//   - the pattern restarts at the start of every subpath, at the offset
//   - strokeDashoffset may be negative or larger than the pattern (wraps)
//   - a closed subpath whose pattern is "on" at distance 0 JOINS its last dash
//     to its first one (SkDashPath), so the start corner gets a real join
//     instead of two butt ends
//   - a zero-length dash paints a dot with round/square caps and nothing with
//     butt caps
// Not handled: percentage lengths (relative to the viewport diagonal); a
// percentage anywhere in the list falls back to a solid stroke.
#pragma once

#include <string>
#include <vector>

#include "impeller.h"

namespace rni {

// Applies the odd-repeat / negative / zero-sum rules. Returns an even-length
// pattern, or an empty vector meaning "stroke solid".
std::vector<float> NormaliseSvgDashArray(const std::vector<float>& raw);

// Dashes `d` with a NORMALISED pattern. `capDots`: the stroke cap is round or
// square, so zero-length dashes must still paint. Returns a new path the
// caller releases, or nullptr when it cannot dash (unparseable `d`, or more
// than kMaxSvgDashes dashes), in which case the caller strokes solid.
// `dashesOut` (optional) receives the number of dashes emitted.
ImpellerPath BuildDashedSvgPath(const std::string& d,
                                const std::vector<float>& pattern,
                                float offset, bool capDots,
                                int* dashesOut = nullptr);

// Skia's own guard against a tiny pattern on a huge path (kMaxDashCount).
constexpr int kMaxSvgDashes = 100000;

}  // namespace rni
