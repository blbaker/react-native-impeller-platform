'use strict';
// desktop-input-gap P0 item 1. onKeyDown/onKeyUp view-config extension for
// the `impeller` platform.
//
// WHY THIS EXISTS: BaseViewConfig.ios.js (what the PLATFORM_FORKED redirect
// in ../index.js used to point bare BaseViewConfig.js at, before this file
// existed) declares NEITHER bubblingEventTypes.topKeyDown/topKeyUp NOR
// validAttributes.onKeyDown/onKeyUp -- RN 0.86's C++ BaseViewEventEmitter has
// no onKeyDown/onKeyUp method at all (see docs/eng/desktop-input-gap.md), and
// the JS-side view config for a plain <View> never declared the matching
// bubbling registration either. So even though FabricHost.cpp's
// dispatchKeyEvent dispatches a generic 'keyDown'/'keyUp' RawEvent (which
// EventEmitter::normalizeEventType turns into exactly 'topKeyDown'/
// 'topKeyUp'), nothing in the view config told Fabric's event system that
// name maps to an onKeyDown/onKeyUp prop -- the native side would be fully
// wired and JS would never hear it. Same "native perfect, JS never told"
// shape Alert.js's self-branching produced (see Alert.impeller.js), one
// layer further down the stack.
//
// We do NOT vendor a copy of BaseViewConfig.ios.js: this delegates to RN's
// own file (requested with its EXPLICIT .ios.js extension so metro resolves
// it directly, bypassing the platform-redirect machinery this same module
// implements -- requesting the bare 'BaseViewConfig.js' specifier here would
// recurse into this exact shim) and ADDS the two event names, so an RN bump
// carries the bulk of the content and only the keys named here are ours to
// maintain.
const BaseViewConfigIosModule = require('react-native/Libraries/NativeComponent/BaseViewConfig.ios.js');
const BaseViewConfigIos = BaseViewConfigIosModule.default || BaseViewConfigIosModule;

const BaseViewConfigImpeller = {
  ...BaseViewConfigIos,
  bubblingEventTypes: {
    ...BaseViewConfigIos.bubblingEventTypes,
    // Matches the shape every other bubbling entry in BaseViewConfig.ios.js
    // uses (topPress -> onPress/onPressCapture, etc.) and the react-native-
    // windows/react-native-macos onKeyDown/onKeyUp payload fields (key, code,
    // altKey, ctrlKey, metaKey, shiftKey) FabricHost::dispatchKeyEvent sends.
    topKeyDown: {
      phasedRegistrationNames: {
        bubbled: 'onKeyDown',
        captured: 'onKeyDownCapture',
      },
    },
    topKeyUp: {
      phasedRegistrationNames: {
        bubbled: 'onKeyUp',
        captured: 'onKeyUpCapture',
      },
    },
  },
  validAttributes: {
    ...BaseViewConfigIos.validAttributes,
    onKeyDown: true,
    onKeyDownCapture: true,
    onKeyUp: true,
    onKeyUpCapture: true,
  },
};

module.exports = BaseViewConfigImpeller;
module.exports.default = BaseViewConfigImpeller;
