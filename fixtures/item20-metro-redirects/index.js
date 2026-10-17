/**
 * parity item 20 fixture: the Metro redirects HostApp needed in its own
 * metro.config.js now ship in react-native-impeller-platform.
 *
 * Each REDIRECT_* line proves one redirect, from inside the bundle:
 *   BACKHANDLER   Utilities/BackHandler.js is a self re-export; without the
 *                 redirect its default export is undefined.
 *   A11Y_EVENT    legacySendAccessibilityEvent, same shape.
 *   HOVER_FLAG    ReactNativeFeatureFlags: after override(), the hover flag
 *                 must read true (upstream ignores override for it).
 * The dev-bundle half (ReactDevToolsSettingsManager, ios-only file) is proved
 * by the gate BUILDING a --dev true bundle at all.
 */
import React from 'react';
import {AppRegistry, BackHandler, View} from 'react-native';
import legacySendAccessibilityEvent from 'react-native/Libraries/Components/AccessibilityInfo/legacySendAccessibilityEvent';
import * as FeatureFlags from 'react-native/src/private/featureflags/ReactNativeFeatureFlags';

function line(name, value) {
  console.log('REDIRECT_' + name + ' ' + value);
}

line('BACKHANDLER', typeof (BackHandler && BackHandler.addEventListener));
line('A11Y_EVENT', typeof legacySendAccessibilityEvent);
try {
  FeatureFlags.override({shouldPressibilityUseW3CPointerEventsForHover: () => true});
} catch (e) {
  line('HOVER_FLAG_OVERRIDE_THREW', e && e.message);
}
line('HOVER_FLAG', String(FeatureFlags.shouldPressibilityUseW3CPointerEventsForHover()));

function Fixture() {
  return <View style={{width: 400, height: 300, backgroundColor: '#111111'}} />;
}

AppRegistry.registerComponent('Item20Redirects', () => Fixture);
