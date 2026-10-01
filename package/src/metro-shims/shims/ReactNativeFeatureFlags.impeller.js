'use strict';
// parity item 20 (moved here from HostApp's app-level metro-shims, ENG-09b).
// Redirect target for react-native/src/private/featureflags/
// ReactNativeFeatureFlags on platform 'impeller' only.
//
// WHY THIS FILE EXISTS
// Upstream defines shouldPressibilityUseW3CPointerEventsForHover through
// createNativeFlagGetter, which reads NativeReactNativeFeatureFlagsCxx (a
// TurboModule this engine does not register) and falls back to its default,
// false, when the module is absent. An app's override() call only feeds the
// OTHER getter family (createJavaScriptFlagGetter's shared `overrides`), so
// overriding this flag was silently a no-op and Pressability never called
// onHoverIn. Measured in HostApp: a synthesised hover_enter on a Button logged
// {"hover":false}.
//
// Fix, scoped to this ONE flag: re-export every other flag from the real
// module untouched, and redefine this one through createJavaScriptFlagGetter,
// which reads the same `overrides` object override()/setOverrides install.
//
// The require() below reaches the REAL upstream file: the resolver exempts
// requests whose origin IS this shim, so it is not redirected back here.
const real = require('react-native/src/private/featureflags/ReactNativeFeatureFlags');
const {
  createJavaScriptFlagGetter,
} = require('react-native/src/private/featureflags/ReactNativeFeatureFlagsBase');

const shim = Object.create(real);
Object.defineProperty(shim, 'shouldPressibilityUseW3CPointerEventsForHover', {
  value: createJavaScriptFlagGetter(
    'shouldPressibilityUseW3CPointerEventsForHover',
    false,
  ),
  enumerable: true,
});

module.exports = shim;
