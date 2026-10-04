/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 * react-native-impeller: vendored from RN 0.86 platform/tvos, plus
 * `elevation` (see the header).
 */

#include "HostPlatformViewProps.h"

#include <react/renderer/core/propsConversions.h>

namespace facebook::react {

HostPlatformViewProps::HostPlatformViewProps(
    const PropsParserContext& context,
    const HostPlatformViewProps& sourceProps,
    const RawProps& rawProps)
    : BaseViewProps(context, sourceProps, rawProps),
      focusable(convertRawProp(
          context,
          rawProps,
          "focusable",
          sourceProps.focusable,
          false)),
      elevation(convertRawProp(
          context,
          rawProps,
          "elevation",
          sourceProps.elevation,
          {})) {}

void HostPlatformViewProps::setProp(
    const PropsParserContext& context,
    RawPropsPropNameHash hash,
    const char* propName,
    const RawValue& value) {
  BaseViewProps::setProp(context, hash, propName, value);

  static auto defaults = HostPlatformViewProps{};

  switch (hash) {
    RAW_SET_PROP_SWITCH_CASE_BASIC(focusable);
    RAW_SET_PROP_SWITCH_CASE_BASIC(elevation);
  }
}

} // namespace facebook::react
