/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

// The Impeller platform's copy of React Native's
// graphics/platform/cxx/react/renderer/graphics/HostPlatformColor.h.
// engine/cmake/ReactCommonFabric.cmake puts engine/fabric/platform/impeller
// ahead of ${RR}/graphics/platform/cxx, so every
// <react/renderer/graphics/HostPlatformColor.h> resolves here, the same way
// PlatformColorParser.h does.
//
// One change from upstream: a real colour is never packed to 0. Upstream packs
// rgba(0,0,0,0) to 0, which is also UndefinedColor, so a `transparent` prop and
// an unset prop were the same SharedColor by the time anything read them. Every
// "is a colour set" check then took its fallback: transparent borders, outlines
// and shadows painted opaque black, transparent text painted black or took its
// parent's colour, and a transparent gradient stop read as a colour hint.
//
// UndefinedColor stays 0, so zero-initialised memory still means unset. A
// colour that would pack to 0 becomes kTransparentColor instead: alpha 0 and
// blue 1, which paints exactly like rgba(0,0,0,0). JS still sends 0 for
// `transparent`; the props parser turns that int into components and comes back
// through hostPlatformColorFromComponents, so the fix applies there.

#pragma once

#include <react/renderer/graphics/ColorComponents.h>
#include <cmath>
#include <cstdint>

// BackgroundLayers.cpp checks for this macro, so a build that picks up the
// stock header instead fails to compile rather than painting black.
#define RNI_IMPELLER_HOST_PLATFORM_COLOR 1

namespace facebook::react {

using Color = int32_t;

namespace HostPlatformColor {
constexpr facebook::react::Color UndefinedColor = 0;
}

// rgba(0,0,0,0) as a set colour: alpha 0, so it paints nothing, and not 0, so
// it is not mistaken for "unset".
constexpr Color kTransparentColor = 0x00000001;

constexpr inline Color hostPlatformColorFromRGBA(uint8_t r, uint8_t g, uint8_t b, uint8_t a)
{
  const Color color = static_cast<Color>(
      (static_cast<uint32_t>(a) << 24) | (static_cast<uint32_t>(r) << 16) |
      (static_cast<uint32_t>(g) << 8) | static_cast<uint32_t>(b));
  return color == HostPlatformColor::UndefinedColor ? kTransparentColor : color;
}

static_assert(
    hostPlatformColorFromRGBA(0, 0, 0, 0) != HostPlatformColor::UndefinedColor,
    "a transparent colour must not equal the unset colour");

inline Color hostPlatformColorFromComponents(ColorComponents components)
{
  float ratio = 255;
  return hostPlatformColorFromRGBA(
      static_cast<uint8_t>(std::round(components.red * ratio)),
      static_cast<uint8_t>(std::round(components.green * ratio)),
      static_cast<uint8_t>(std::round(components.blue * ratio)),
      static_cast<uint8_t>(std::round(components.alpha * ratio)));
}

inline float alphaFromHostPlatformColor(Color color)
{
  return static_cast<float>((color >> 24) & 0xff);
}

inline float redFromHostPlatformColor(Color color)
{
  return static_cast<float>((color >> 16) & 0xff);
}

inline float greenFromHostPlatformColor(Color color)
{
  return static_cast<float>((color >> 8) & 0xff);
}

inline float blueFromHostPlatformColor(Color color)
{
  return static_cast<uint8_t>((color >> 0) & 0xff);
}

inline bool hostPlatformColorIsColorMeaningful(Color color) noexcept
{
  return alphaFromHostPlatformColor(color) > 0;
}

inline ColorComponents colorComponentsFromHostPlatformColor(Color color)
{
  float ratio = 255;
  return ColorComponents{
      .red = static_cast<float>(redFromHostPlatformColor(color)) / ratio,
      .green = static_cast<float>(greenFromHostPlatformColor(color)) / ratio,
      .blue = static_cast<float>(blueFromHostPlatformColor(color)) / ratio,
      .alpha = static_cast<float>(alphaFromHostPlatformColor(color)) / ratio};
}

} // namespace facebook::react
