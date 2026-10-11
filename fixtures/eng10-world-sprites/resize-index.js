/**
 * ENG-10 world-sprites gate -- RESIZE FIXTURE (buffer size change mid-session).
 *
 * The same <world> node, the same sprite list, but the TERRAIN BUFFER changes
 * SIZE while the app is running -- exactly what a zoom does in a real world
 * app. Frame 1 publishes a HALF-size terrain (160x120, stretched over the
 * 320x240 node). A tap swaps in the full-size 320x240 terrain from scene.js.
 * After the swap the frame must be pixel-identical to the CPU-composite
 * oracle (reference-index.js), the same oracle ci-world-sprites.sh ARM B uses.
 *
 * Why this exists: every other world fixture calls setPixels ONCE, at one
 * size, so paintWorldNode's sizeChanged branch only ever ran on the FIRST
 * upload (glTex == 0). The REALLOCATE-and-re-adopt half of that branch -- the
 * path a zoom takes -- was never executed by any gate.
 *
 * The tap target is a transparent full-bleed Pressable on top of the world:
 * it paints nothing, so the oracle compare is unaffected.
 */
import React from 'react';
import {AppRegistry, Pressable, View} from 'react-native';
import * as NativeComponentRegistry from 'react-native/Libraries/NativeComponent/NativeComponentRegistry';
import WorldRaster from '@react-native-impeller/core/src/worldraster';
import {WIDTH, HEIGHT, ATLAS, ATLAS_IDS, buildTerrain, buildAtlasEntry, buildSprites} from './scene';

const World = NativeComponentRegistry.get('world', () => ({
  uiViewClassName: 'world',
  bubblingEventTypes: {},
  directEventTypes: {},
  validAttributes: {name: true},
}));
const WORLD_NAME = 'eng10-gate-resize';

// Size A. Deliberately NOT the node size and NOT the size-B buffer, so the
// swap to B takes the reallocate branch (texW/texH change), never the
// same-size glTexSubImage2D branch.
const A_W = WIDTH / 2;
const A_H = HEIGHT / 2;

// A flat mid-grey terrain at size A. Its only job is to be visibly different
// from B, so a render stuck on the stale A texture fails the oracle compare.
function buildTerrainA() {
  const buf = new ArrayBuffer(A_W * A_H * 4);
  const b = new Uint8Array(buf);
  for (let i = 0; i < b.length; i += 4) {
    b[i] = 200;
    b[i + 1] = 200;
    b[i + 2] = 200;
    b[i + 3] = 255;
  }
  return buf;
}

// The ATLAS resize arm. 'bubble' is first registered at HALF its native size
// (8x8, solid green: visibly wrong), then re-registered at its native 16x16 by
// the tap. paintWorldSprites has its own sizeChanged/re-adopt branch with the
// same ownership hazard as the terrain; this is what makes it run.
const RESIZED_SPRITE = 'bubble';
function buildHalfBubble() {
  const w = ATLAS[RESIZED_SPRITE].w / 2;
  const h = ATLAS[RESIZED_SPRITE].h / 2;
  const buf = new ArrayBuffer(w * h * 4);
  const b = new Uint8Array(buf);
  for (let i = 0; i < b.length; i += 4) {
    b[i] = 0;
    b[i + 1] = 255;
    b[i + 2] = 0;
    b[i + 3] = 255;
  }
  return {buf, w, h};
}

function Resize() {
  React.useEffect(() => {
    WorldRaster.setPixels(WORLD_NAME, buildTerrainA(), A_W, A_H);
    for (const id of ATLAS_IDS) {
      if (id === RESIZED_SPRITE) {
        const half = buildHalfBubble();
        WorldRaster.registerSprite(id, half.buf, half.w, half.h);
      } else {
        WorldRaster.registerSprite(id, buildAtlasEntry(id), ATLAS[id].w, ATLAS[id].h);
      }
    }
    const sprites = buildSprites();
    WorldRaster.drawSprites(WORLD_NAME, sprites);
    console.log(`ENG10_RESIZE size=A w=${A_W} h=${A_H} sprites=${sprites.length}`);
  }, []);

  const onPress = () => {
    WorldRaster.setPixels(WORLD_NAME, buildTerrain(), WIDTH, HEIGHT);
    WorldRaster.registerSprite(
      RESIZED_SPRITE,
      buildAtlasEntry(RESIZED_SPRITE),
      ATLAS[RESIZED_SPRITE].w,
      ATLAS[RESIZED_SPRITE].h,
    );
    console.log(`ENG10_RESIZE size=B w=${WIDTH} h=${HEIGHT}`);
  };

  return (
    <View style={{width: WIDTH, height: HEIGHT, backgroundColor: '#ffffff'}}>
      <World
        name={WORLD_NAME}
        style={{position: 'absolute', left: 0, top: 0, width: WIDTH, height: HEIGHT}}
      />
      <Pressable
        onPress={onPress}
        style={{position: 'absolute', left: 0, top: 0, width: WIDTH, height: HEIGHT}}
      />
    </View>
  );
}

AppRegistry.registerComponent('Eng10Resize', () => Resize);
