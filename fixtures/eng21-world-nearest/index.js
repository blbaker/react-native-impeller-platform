/**
 * ENG-21 fixture: per-<world> nearest-neighbour sampling for the setPixels
 * terrain AND registerSprite sprites.
 *
 * Two <world> nodes draw the SAME pixel art, magnified by an integer K = 12:
 *   world 'eng21-nearest' (top, y 0)   -> WorldRaster.setSampling(.., 'nearest')
 *   world 'eng21-linear'  (lower, y 120) -> never set: the default (linear)
 * Each: a 20 x 8 texel terrain stretched to 240 x 96 pt, plus one 4 x 4 texel
 * sprite drawn at (24, 24) sized 48 x 48 pt.
 *
 * Every texel differs from all four neighbours (terrain index = (tx + 2*ty)
 * mod 4; the sprite is a black/white checker), so a linear filter blends at
 * EVERY texel edge, while nearest paints only palette colours. The gate
 * (tools/ci-world-nearest.sh) compares each world to a CPU nearest composite.
 *
 * Also probes the strict contract: an unknown mode must THROW.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import * as NativeComponentRegistry from 'react-native/Libraries/NativeComponent/NativeComponentRegistry';
import WorldRaster from '@react-native-impeller/core/src/worldraster';

const World = NativeComponentRegistry.get('world', () => ({
  uiViewClassName: 'world',
  bubblingEventTypes: {},
  directEventTypes: {},
  validAttributes: {name: true},
}));

const TW = 20;
const TH = 8;
const K = 12;
const PALETTE = [
  [220, 40, 40],
  [40, 180, 60],
  [40, 60, 220],
  [240, 220, 40],
];

function terrain() {
  const buf = new ArrayBuffer(TW * TH * 4);
  const b = new Uint8Array(buf);
  for (let y = 0; y < TH; y++) {
    for (let x = 0; x < TW; x++) {
      const c = PALETTE[(x + 2 * y) % 4];
      const o = (y * TW + x) * 4;
      b[o] = c[0];
      b[o + 1] = c[1];
      b[o + 2] = c[2];
      b[o + 3] = 255;
    }
  }
  return buf;
}

function checker() {
  const buf = new ArrayBuffer(4 * 4 * 4);
  const b = new Uint8Array(buf);
  for (let y = 0; y < 4; y++) {
    for (let x = 0; x < 4; x++) {
      const v = (x + y) % 2 === 0 ? 0 : 255;
      const o = (y * 4 + x) * 4;
      b[o] = v;
      b[o + 1] = v;
      b[o + 2] = v;
      b[o + 3] = 255;
    }
  }
  return buf;
}

const NEAREST = 'eng21-nearest';
const LINEAR = 'eng21-linear';

function Fixture() {
  React.useEffect(() => {
    // An engine without ENG-21 still renders (both worlds linear), so the gate
    // fails on PIXELS, the same way ROOM-1 claim 11 does, not on a JS crash.
    if (WorldRaster.isSamplingSupported()) {
      try {
        WorldRaster.setSampling(NEAREST, 'nearst');
        console.log('ENG21_THROW_MISSING bad-mode');
      } catch (e) {
        console.log('ENG21_THROW_OK bad-mode');
      }
      WorldRaster.setSampling(NEAREST, 'nearest');
    } else {
      console.log('ENG21_NO_SETSAMPLING');
    }
    WorldRaster.registerSprite('eng21-checker', checker(), 4, 4);
    for (const name of [NEAREST, LINEAR]) {
      WorldRaster.setPixels(name, terrain(), TW, TH);
      WorldRaster.drawSprites(name, [
        {textureId: 'eng21-checker', x: 2 * K, y: 2 * K, w: 4 * K, h: 4 * K},
      ]);
    }
    console.log('ENG21_READY');
  }, []);

  const box = top => ({position: 'absolute', left: 0, top, width: TW * K, height: TH * K});
  return (
    <View style={{width: 320, height: 240, backgroundColor: '#ffffff'}}>
      <World name={NEAREST} style={box(0)} />
      <World name={LINEAR} style={box(120)} />
    </View>
  );
}

AppRegistry.registerComponent('Eng21Nearest', () => Fixture);
