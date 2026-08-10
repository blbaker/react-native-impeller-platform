'use strict';
// Alert shim for the `impeller` platform.
//
// ⛔ WHY THIS FILE EXISTS: RN's `Libraries/Alert/Alert.js` BRANCHES ITSELF OUT
// OF EXISTENCE on any platform that is not ios or android.
//
//     static alert(...) {
//       if (Platform.OS === 'ios') { ...prompt... }
//       else if (Platform.OS === 'android') { ...DialogManager... }
//     }                                   // <-- no else. Silent no-op.
//
// There is no error, no warning, and no dead import to grep for. The
// AlertManager TurboModule can be perfect, registered, cached, and reachable
// from JS — and `Alert.alert()` still does absolutely nothing, because the
// call never leaves JavaScript.
//
// This is a DIFFERENT disease from the self-resolving `RCTAlertManager.js`
// re-export stub (handled by the PLATFORM_FORKED redirect in ../index.js).
// Both had to be fixed for Alert to work, and each one alone leaves the
// feature 100% broken with a completely healthy-looking app. It is also why
// the P4 gate asserts a NATIVE-side counter (`alerts_shown`) as well as a
// pixel: the pixel proves JS got its callback, the counter proves the call
// actually crossed the seam. A JS-side stub could satisfy either alone.
//
// We do NOT vendor a copy of Alert.js. This delegates to RN's own
// `RCTAlertManager` (which our resolver points at the .ios flavour), so RN
// keeps ownership of the payload shape and an RN bump carries its own changes.

const {alertWithArgs} = require('react-native/Libraries/Alert/RCTAlertManager');

class Alert {
  static alert(title, message, buttons, options) {
    Alert.prompt(title, message, buttons, 'default', undefined, undefined, options);
  }

  static prompt(title, message, callbackOrButtons, type, defaultValue, keyboardType, options) {
    // Same normalisation RN's ios branch does. Kept here rather than
    // reimplemented differently, so button indices line up with the callback
    // ids the native side sends back.
    let callbacks = [];
    const buttonSpecs = [];
    let cancelButtonKey;
    let destructiveButtonKey;
    let preferredButtonKey;

    if (typeof callbackOrButtons === 'function') {
      callbacks = [callbackOrButtons];
    } else if (Array.isArray(callbackOrButtons)) {
      callbackOrButtons.forEach((btn, index) => {
        callbacks[index] = btn.onPress;
        if (btn.style === 'cancel') {
          cancelButtonKey = String(index);
        } else if (btn.style === 'destructive') {
          destructiveButtonKey = String(index);
        }
        if (btn.isPreferred) {
          preferredButtonKey = String(index);
        }
        if (btn.text || index < (callbackOrButtons || []).length - 1) {
          const btnDef = {};
          btnDef[index] = btn.text || '';
          buttonSpecs.push(btnDef);
        }
      });
    }

    alertWithArgs(
      {
        title: title || '',
        message: message || undefined,
        buttons: buttonSpecs,
        type: type || undefined,
        defaultValue,
        cancelButtonKey,
        destructiveButtonKey,
        preferredButtonKey,
        keyboardType,
        userInterfaceStyle: (options && options.userInterfaceStyle) || undefined,
      },
      (id, value) => {
        const cb = callbacks[id];
        cb && cb(value);
      },
    );
  }
}

module.exports = Alert;
module.exports.default = Alert;
