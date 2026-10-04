/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 * react-native-impeller: vendored from RN 0.86
 * ReactCommon/react/renderer/components/view/platform/tvos (which adds
 * `focusable` over cxx), plus `elevation`. RN parses elevation only in the
 * ANDROID HostPlatformViewProps; every other variant drops it, so a desktop
 * host that wants to paint it must parse it itself (style audit item 4).
 */

#pragma once

#include <react/renderer/components/view/BaseViewProps.h>
#include <react/renderer/core/PropsParserContext.h>

namespace facebook::react {

class HostPlatformViewProps : public BaseViewProps {
 public:
  HostPlatformViewProps() = default;
  HostPlatformViewProps(
      const PropsParserContext &context,
      const HostPlatformViewProps &sourceProps,
      const RawProps &rawProps);

  void
  setProp(const PropsParserContext &context, RawPropsPropNameHash hash, const char *propName, const RawValue &value);

  bool focusable{false};
  // Android material elevation in points (RN `elevation`). 0 = no shadow.
  Float elevation{};
};

} // namespace facebook::react
