/**
 * ENG-09 world-raster gate — WORLD FIXTURE.
 *
 * Mounts exactly ONE <world name="..."> node filling the whole surface, and
 * calls WorldRaster.setPixels(name, rgba, w, h) with the shared 238-tile
 * grayscale ramp from ./pattern.js, packed as a tightly-packed top-to-bottom
 * RGBA8 buffer (per the JS contract in package/src/worldraster/index.js --
 * this fixture must NOT flip rows itself; the engine does that at paint
 * time).
 *
 * ⛔ WHY setPixels RUNS IN useEffect, NOT AT MODULE SCOPE.
 * WorldRaster.setPixels writes into WorldRasterStore, which SceneGraph's
 * painter reads once per frame. The write must happen only after the
 * <world> node's ShadowNode/ComponentDescriptor exist on the native side,
 * i.e. after Fabric has committed the tree at least once -- useEffect runs
 * post-commit, which is the earliest point that is true. Calling it at
 * module scope would race the very first commit.
 *
 * This is a ONE-WORLD-FRAME fixture: setPixels is called exactly once, no
 * repaint loop, no version churn -- the gate is about the store -> texture
 * -> draw path working AT ALL, not about update cadence.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import * as NativeComponentRegistry from 'react-native/Libraries/NativeComponent/NativeComponentRegistry';
import WorldRaster from '@react-native-impeller/core/src/worldraster';
import {COLS, ROWS, TILE, WIDTH, HEIGHT, levelForTile} from './pattern';

// <world> is a plain host component (engine/fabric/WorldShadowNode.h);
// `name` is the RNSVGImageProps.name field that keys the WorldRasterStore
// entry this node paints from.
//
// ⛔ NativeComponentRegistry.get, NOT requireNativeComponent. This engine
// runs bridgeless (RN$Bridgeless=true — see engine/runtime/ReactHost.cpp),
// and in bridgeless mode NativeComponentRegistry.get() prefers the STATIC
// viewConfigProvider given here over UIManager.getViewManagerConfig(), which
// only exists in the old Paper bridge and always returns null bridgeless.
// requireNativeComponent always asks UIManager and throws "View config not
// found" in this engine — react-native-svg's own NativeComponent files are
// this same call, just codegen-generated instead of hand-written, because
// <world> has no codegen spec of its own (see engine/fabric/WorldShadowNode.h
// for why it borrows RNSVGImageProps on the native side).
const World = NativeComponentRegistry.get('world', () => ({
  uiViewClassName: 'world',
  bubblingEventTypes: {},
  directEventTypes: {},
  validAttributes: {name: true},
}));
const WORLD_NAME = 'eng09-gate-world';

function buildPattern() {
  // Tightly packed RGBA8, row-major, top-to-bottom -- exactly the layout
  // package/src/worldraster/index.js's contract promises the engine will
  // Y-flip at paint time. Each tile is a solid grayscale square; R=G=B=level,
  // A=255 (fully opaque, so a missing-alpha bug cannot masquerade as a
  // correct render against a white background).
  const buf = new ArrayBuffer(WIDTH * HEIGHT * 4);
  const bytes = new Uint8Array(buf);
  for (let row = 0; row < ROWS; row++) {
    for (let col = 0; col < COLS; col++) {
      const level = levelForTile(row * COLS + col);
      for (let py = 0; py < TILE; py++) {
        const y = row * TILE + py;
        for (let px = 0; px < TILE; px++) {
          const x = col * TILE + px;
          const o = (y * WIDTH + x) * 4;
          bytes[o] = level;
          bytes[o + 1] = level;
          bytes[o + 2] = level;
          bytes[o + 3] = 255;
        }
      }
    }
  }
  return buf;
}

function Fixture() {
  React.useEffect(() => {
    WorldRaster.setPixels(WORLD_NAME, buildPattern(), WIDTH, HEIGHT);
  }, []);

  return (
    <View style={{width: WIDTH, height: HEIGHT, backgroundColor: '#ffffff'}}>
      <World
        name={WORLD_NAME}
        style={{position: 'absolute', left: 0, top: 0, width: WIDTH, height: HEIGHT}}
      />
    </View>
  );
}

AppRegistry.registerComponent('Eng09World', () => Fixture);
