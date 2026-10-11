// Replaces RN's graphics/platform/cxx stub, which returns transparent for every
// PlatformColor. Names resolve against PlatformColorTable.h using the host's
// current scheme at prop-parse time (a later scheme change does not re-parse).
#pragma once

#include <react/debug/react_native_expect.h>
#include <react/renderer/core/RawValue.h>
#include <react/renderer/graphics/Color.h>
#include <react/renderer/graphics/fromRawValueShared.h>
#include <react/utils/ContextContainer.h>

#include <string>
#include <unordered_map>
#include <vector>

#include "PlatformColorTable.h"

namespace facebook::react {

inline SharedColor
parsePlatformColor(const ContextContainer & /*contextContainer*/, int32_t /*surfaceId*/, const RawValue &value)
{
  namespace pc = impeller_platform_color;
  const bool dark = pc::darkScheme().load();
  if (value.hasType<std::unordered_map<std::string, RawValue>>()) {
    const auto &items = (std::unordered_map<std::string, RawValue>)value;
    for (const char *key : {"semantic", "resource_paths"}) {
      auto it = items.find(key);
      if (it == items.end() || !it->second.hasType<std::vector<std::string>>()) continue;
      for (const auto &name : (std::vector<std::string>)it->second) {
        if (const pc::Entry *e = pc::find(name)) {
          const pc::Rgba &c = dark ? e->dark : e->light;
          return {colorFromComponents({c.r / 255.f, c.g / 255.f, c.b / 255.f, c.a})};
        }
      }
    }
  }
  return {colorFromComponents({0, 0, 0, 0})};
}

inline void
fromRawValue(const ContextContainer &contextContainer, int32_t surfaceId, const RawValue &value, SharedColor &result)
{
  fromRawValueShared(contextContainer, surfaceId, value, result, parsePlatformColor);
}

} // namespace facebook::react
