'use strict';
// FP-42 — external textures (Flutter's Texture widget + TextureRegistry).
//
// <ImpellerTextureView textureId={id} style={...} /> paints the latest frame of
// the engine's texture `id` inside the view's clip, transform and opacity.
// Native producers (video, camera) register textures from C++; this module
// adds a test producer from JS. Same `get` (not `getEnforcing`) pattern as
// ../worldraster: an engine without the module fails only the calls that need it.

const {TurboModuleRegistry} = require('react-native');
const NativeComponentRegistry = require('react-native/Libraries/NativeComponent/NativeComponentRegistry');

const Native = TurboModuleRegistry.get('ImpellerTextureRegistry');

function mod() {
  if (Native == null) {
    throw new Error(
      'ImpellerTextureRegistry native module is unavailable. The engine binary ' +
        'predates FP-42: external textures cannot work until the engine is updated.',
    );
  }
  return Native;
}

function isSupported() {
  return Native != null && mod().isSupported();
}

// A native animated test pattern at `fps`; returns its texture id. maxFrames > 0
// stops it after that many frames (the last one stays registered).
function registerTestProducer(fps, width, height, maxFrames = 0) {
  return mod().registerTestProducer(fps, width, height, maxFrames);
}

// Stops painting `id` (views showing it paint nothing). False: unknown id.
function unregister(id) {
  return mod().unregister(id);
}

// Tells the engine texture `id` has a new frame (native producers do this).
function markFrameAvailable(id) {
  mod().markFrameAvailable(id);
}

const ImpellerTextureView = NativeComponentRegistry.get('ImpellerTextureView', () => ({
  uiViewClassName: 'ImpellerTextureView',
  bubblingEventTypes: {},
  directEventTypes: {},
  validAttributes: {textureId: true},
}));

module.exports = {
  isSupported,
  registerTestProducer,
  unregister,
  markFrameAvailable,
  ImpellerTextureView,
};
