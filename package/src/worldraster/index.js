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

// ENG-10 — GPU sprite compositing.
//
// registerSprite(textureId, rgba, w, h): upload ONE atlas entry, once.
// rgba: ArrayBuffer of exactly w*h*4 bytes, STRAIGHT (non-premultiplied)
// RGBA8, top-to-bottom — canvas ImageData layout. Re-registering the same
// textureId replaces it.
function registerSprite(textureId, rgba, w, h) {
  mod().registerSprite(textureId, rgba, w, h);
}

// drawSprites(id, sprites): per frame. `id` is the <world name> to composite
// over; sprites is an Array<{textureId, x, y, w, h, alpha?}> in layout points,
// BACK-TO-FRONT (list order is paint order). Throws on an unregistered
// textureId. Pass [] to clear.
function drawSprites(id, sprites) {
  mod().drawSprites(id, sprites);
}

// ENG-21 — setSampling(id, mode): how <world name=id> samples its setPixels
// terrain and every sprite drawn on it. mode 'nearest' keeps pixel-art edges
// hard at an integer scale; 'linear' (the default) blends neighbouring texels.
// Throws on any other mode. Engines built before ENG-21 lack the method; call
// isSamplingSupported() first if the app must run on them.
function setSampling(id, mode) {
  mod().setSampling(id, mode);
}

function isSamplingSupported() {
  return Native != null && typeof Native.setSampling === 'function';
}

module.exports = {
  isSupported,
  isSamplingSupported,
  setPixels,
  registerSprite,
  drawSprites,
  setSampling,
};
