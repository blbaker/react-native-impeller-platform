#pragma once
// FP-41: backdrop blur for expo-blur's BlurView. Modelled on Flutter's
// ClipRect(BackdropFilter(ImageFilter.blur, child: tint)): the clip bounds the
// layer, SaveLayer's backdrop filter seeds it with the blurred content already
// painted beneath (impeller/display_list/canvas.cc Canvas::SaveLayer ->
// backdrop_filter_contents), and the tint is drawn into the layer on top.
#include <string>

#include "impeller.h"

namespace rni {

// The tint overlay for an expo-blur `tint` at `intensity` (0..100), straight
// sRGB 0..1. Table: expo-blur src/getBackgroundColor.ts (Apple iOS 14 kit).
ImpellerColor BlurTintColor(const std::string& tint, float intensity);

// Gaussian sigma (points) for `intensity`. expo-blur's Android view uses the
// intensity as the blur radius; Flutter converts radius to sigma with
// r / sqrt(3) + 0.5 (impeller/geometry/sigma.cc Radius::operator Sigma).
float BlurSigmaForIntensity(float intensity);

// Paints the blur view in the CURRENT clip (the caller has clipped to the
// view's (rounded) box). Nothing is drawn at intensity <= 0.
void PaintBackdropBlur(ImpellerDisplayListBuilder builder, const ImpellerRect& box,
                       const std::string& tint, float intensity);

}  // namespace rni
