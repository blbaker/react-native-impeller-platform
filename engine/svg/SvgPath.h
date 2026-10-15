// SvgPath — parses an SVG `d` attribute into an ImpellerPathBuilder.
//
// We do NOT have Skia here (that is what skia-platform used, via
// SkParsePath::FromSVGString). Impeller ships no SVG path parser of its own,
// only the primitive MoveTo/LineTo/QuadraticCurveTo/CubicCurveTo/Close
// builder calls — so this is our own minimal parser, converting every SVG
// path command onto those primitives.
#pragma once

#include <string>
#include <string_view>

#include "impeller.h"

namespace rni {

// Receives the parsed geometry, already absolute, with S/T reflected and arcs
// converted to cubics. ParseSvgPathToBuilder feeds an Impeller builder; the
// ENG-13 dasher (svg/SvgDash) feeds a sink that measures and cuts it, so both
// read the SAME parse and a dashed stroke can never disagree with its fill.
class SvgPathSink {
 public:
  virtual ~SvgPathSink() = default;
  virtual void moveTo(float x, float y) = 0;
  virtual void lineTo(float x, float y) = 0;
  virtual void quadTo(float cx, float cy, float x, float y) = 0;
  virtual void cubicTo(float c1x, float c1y, float c2x, float c2y, float x,
                       float y) = 0;
  virtual void close() = 0;
};

// Parses `d` onto `sink`. Same return contract as ParseSvgPathToBuilder.
bool ParseSvgPath(std::string_view d, SvgPathSink& sink);

// Appends the geometry described by `d` onto `builder` (which the caller
// already owns — this does not create or release it). Returns false if `d`
// could not be parsed at all (empty, or does not start with a moveto); a
// partially-valid path (trailing garbage) still returns true with whatever
// geometry parsed before the error, matching browsers' "renders what it
// understood" behaviour rather than discarding a whole icon over one bad
// digit.
//
// Supports: M/m L/l H/h V/v C/c S/s Q/q T/t A/a Z/z — the full command set
// SVG 1.1 paths use. Arcs are converted to cubic Bezier segments (Impeller's
// path builder has no native arc-to primitive taking rotation + large-arc +
// sweep flags), using the standard endpoint-to-center parameterization from
// the SVG spec, so an elliptical arc renders as itself and not a
// visually-similar substitute.
bool ParseSvgPathToBuilder(const std::string& d,
                           ImpellerPathBuilder builder);

}  // namespace rni
