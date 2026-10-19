'use strict';
// Desktop notifications, the JS half of the engine's Notifications module.
//
//   requestPermission() -> Promise<{status, reason?}>
//   show({title, body, id, data}) -> Promise<{status, id, reason?}>
//   onPress(listener) -> {remove()}; listener gets {id, data, action}
//
// The engine owns the OS call (freedesktop D-Bus on Linux,
// UNUserNotificationCenter on macOS, toast notifications on Windows). This
// file owns the shape: argument checks, the JSON encoding of `data`, and the
// subscription. `data` goes to native as a JSON string and comes back on press
// unchanged, so native never has to understand it.
//
// Nothing here throws for a missing capability. An engine without the module
// (built before it existed, or running on a platform with no backend) answers
// {status: 'unavailable', reason}, the same answer the engine gives when the
// OS service is missing. Bad arguments are programmer errors and reject.

const {DeviceEventEmitter, TurboModuleRegistry} = require('react-native');

// get, not getEnforcing: a missing module must fail this feature, not the
// whole bundle at import time.
const Native = TurboModuleRegistry.get('Notifications');

// Emitted by the engine (ReactHost.cpp) when the user clicks a notification
// this app showed.
const PRESS_EVENT = 'rniNotificationPress';

const MISSING_REASON =
  'this engine has no Notifications module (run `rn-impeller --list-modules` to check)';

let generated = 0;

async function requestPermission() {
  if (Native == null) return {status: 'unavailable', reason: MISSING_REASON};
  return Native.requestPermission();
}

function checkOptions(options) {
  if (options == null || typeof options !== 'object') {
    throw new TypeError('show() wants an options object {title, body, id, data}');
  }
  const {title, body = '', id} = options;
  if (typeof title !== 'string' || title.length === 0) {
    throw new TypeError('show(): title must be a non-empty string');
  }
  if (typeof body !== 'string') {
    throw new TypeError('show(): body must be a string');
  }
  if (id != null && (typeof id !== 'string' || id.length === 0)) {
    throw new TypeError('show(): id must be a non-empty string when given');
  }
  let dataJson;
  try {
    dataJson = JSON.stringify(options.data === undefined ? null : options.data);
  } catch (error) {
    throw new TypeError('show(): data must be JSON-serialisable: ' + error.message);
  }
  if (dataJson === undefined) {
    // JSON.stringify returns undefined for a function or a symbol.
    throw new TypeError('show(): data must be JSON-serialisable');
  }
  generated += 1;
  return {title, body, id: id == null ? `rni-${Date.now()}-${generated}` : id, dataJson};
}

// Showing an id that is already on screen replaces that notification.
async function show(options) {
  const {title, body, id, dataJson} = checkOptions(options);
  if (Native == null) return {status: 'unavailable', id, reason: MISSING_REASON};
  const result = await Native.show(title, body, id, dataJson);
  return {...result, id};
}

function decodeData(raw) {
  if (typeof raw !== 'string') return null;
  try {
    return JSON.parse(raw);
  } catch (error) {
    // Native echoes exactly what show() encoded, so this only happens for a
    // payload that did not come from this file. Report it as no data.
    return null;
  }
}

function onPress(listener) {
  if (typeof listener !== 'function') {
    throw new TypeError('onPress() wants a function');
  }
  return DeviceEventEmitter.addListener(PRESS_EVENT, event => {
    listener({id: event.id, action: event.action, data: decodeData(event.data)});
  });
}

module.exports = {requestPermission, show, onPress, PRESS_EVENT};
