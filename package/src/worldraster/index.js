'use strict';
// ENG-09 — WorldRaster JS shim.
//
// The engine vends ONE primitive: WorldRaster.setPixels(id, rgba, w, h),
// synchronous, throwing on a mismatched buffer. This file is a thin,
// defensive wrapper -- same `get` (not `getEnforcing`) pattern as
// package/src/storage/index.js, so an engine built before ENG-09 fails the
// one call site that needs WorldRaster rather than taking the whole bundle
// down at import.

const {TurboModuleRegistry} = require('react-native');

const Native = TurboModuleRegistry.get('WorldRaster');

function mod() {
  if (Native == null) {
    throw new Error(
      'WorldRaster native module is unavailable. The engine binary predates ' +
        'ENG-09 — world raster calls cannot work until the engine is updated.',
    );
  }
  return Native;
}

function isSupported() {
  return Native != null && mod().isSupported();
}

// id: string — must match the `name` prop set on the <world> host component
// this buffer is meant for. rgba: ArrayBuffer of exactly w*h*4 bytes,
// tightly packed RGBA8, row-major, top-to-bottom (the engine performs the
// Y-flip at paint time; callers never flip).
function setPixels(id, rgba, w, h) {
  mod().setPixels(id, rgba, w, h);
}

module.exports = {
  isSupported,
  setPixels,
};
