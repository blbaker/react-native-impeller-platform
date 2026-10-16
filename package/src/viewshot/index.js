'use strict';
// FP-43 — react-native-view-shot's JS API on the engine's RNViewShot module.
//
// The engine implements view-shot's native module (captureRef, captureScreen,
// releaseCapture), so an app that depends on react-native-view-shot works as
// is; this file is the same surface for apps that do not. The snapshot renders
// the view's subtree into an offscreen on the raster thread, the png/jpg is
// encoded off the JS thread, and the Promise resolves on the JS thread.
//
// options: {format: 'png' | 'jpg', quality: 0..1, result: 'tmpfile' | 'base64'
// | 'data-uri', width, height (output pixels), fileName}.

const {TurboModuleRegistry, findNodeHandle} = require('react-native');

const Native = TurboModuleRegistry.get('RNViewShot');

function mod() {
  if (Native == null) {
    throw new Error(
      'RNViewShot native module is unavailable. The engine binary predates FP-43: ' +
        'view snapshots cannot work until the engine is updated.',
    );
  }
  return Native;
}

const DEFAULTS = {format: 'png', quality: 1, result: 'tmpfile'};

// view-shot's validateOptions: defaults filled in, bad values reported.
function validateOptions(input) {
  const options = {...DEFAULTS, ...(input || {})};
  const errors = [];
  if ('width' in options && (typeof options.width !== 'number' || options.width <= 0)) {
    errors.push('option width should be a positive number');
    delete options.width;
  }
  if ('height' in options && (typeof options.height !== 'number' || options.height <= 0)) {
    errors.push('option height should be a positive number');
    delete options.height;
  }
  if (typeof options.quality !== 'number' || options.quality < 0 || options.quality > 1) {
    errors.push('option quality should be a number between 0.0 and 1.0');
    options.quality = DEFAULTS.quality;
  }
  if (options.format === 'jpeg') options.format = 'jpg';
  if (options.format !== 'png' && options.format !== 'jpg') {
    errors.push(`option format '${options.format}' is not in valid formats: png | jpg`);
    options.format = DEFAULTS.format;
  }
  if (!['tmpfile', 'base64', 'data-uri'].includes(options.result)) {
    errors.push(`option result '${options.result}' is not in valid results: tmpfile | base64 | data-uri`);
    options.result = DEFAULTS.result;
  }
  return {options, errors};
}

function toTag(view) {
  if (view && typeof view === 'object' && 'current' in view) view = view.current;
  if (typeof view === 'number') return view;
  const tag = view == null ? null : findNodeHandle(view);
  if (tag == null) throw new Error('findNodeHandle failed to resolve view=' + String(view));
  return tag;
}

// Resolves with a file:// uri, base64 or a data uri (options.result).
function captureRef(view, optionsObject) {
  let tag;
  try {
    tag = toTag(view);
  } catch (e) {
    return Promise.reject(e);
  }
  const {options, errors} = validateOptions(optionsObject);
  if (__DEV__ && errors.length > 0) {
    console.warn('react-native-view-shot captureRef options: ' + errors.join(', '));
  }
  return mod().captureRef(tag, options);
}

function captureScreen(optionsObject) {
  const {options, errors} = validateOptions(optionsObject);
  if (__DEV__ && errors.length > 0) {
    console.warn('react-native-view-shot captureScreen options: ' + errors.join(', '));
  }
  return mod().captureScreen(options);
}

// Deletes a tmpfile capture.
function releaseCapture(uri) {
  if (typeof uri !== 'string') return;
  mod().releaseCapture(uri);
}

function isSupported() {
  return Native != null;
}

module.exports = {captureRef, captureScreen, releaseCapture, isSupported};
