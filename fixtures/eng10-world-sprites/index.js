/**
 * ENG-10 world-sprites gate — SPRITES FIXTURE (the new GPU path).
 *
 * ONE <world> node. Terrain goes through ENG-09 setPixels; the sprite atlas is
 * uploaded once via registerSprite; the whole back-to-front list goes through
 * ONE drawSprites call. No per-sprite React nodes -- that is the point.
 *
 * Also probes the strict-throw contract (bad byteLength, unregistered
 * textureId) and logs a marker the gate greps for. Runs in useEffect for the
 * same post-commit reason as the ENG-09 fixture.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import * as NativeComponentRegistry from 'react-native/Libraries/NativeComponent/NativeComponentRegistry';
import WorldRaster from 'react-native-impeller-platform/src/worldraster';
import {WIDTH, HEIGHT, ATLAS, ATLAS_IDS, buildTerrain, buildAtlasEntry, buildSprites} from './scene';

const World = NativeComponentRegistry.get('world', () => ({
  uiViewClassName: 'world',
  bubblingEventTypes: {},
  directEventTypes: {},
  validAttributes: {name: true},
}));
const WORLD_NAME = 'eng10-gate-world';

function probeThrows(label, fn) {
  try {
    fn();
    console.log(`ENG10_THROW_MISSING ${label}`);
  } catch (e) {
    console.log(`ENG10_THROW_OK ${label}`);
  }
}

function Fixture() {
  React.useEffect(() => {
    WorldRaster.setPixels(WORLD_NAME, buildTerrain(), WIDTH, HEIGHT);
    probeThrows('bad-length', () =>
      WorldRaster.registerSprite('bad', new ArrayBuffer(7), 2, 2),
    );
    for (const id of ATLAS_IDS) {
      WorldRaster.registerSprite(id, buildAtlasEntry(id), ATLAS[id].w, ATLAS[id].h);
    }
    probeThrows('unregistered-id', () =>
      WorldRaster.drawSprites(WORLD_NAME, [{textureId: 'never-registered', x: 0, y: 0, w: 4, h: 4}]),
    );
    const sprites = buildSprites();
    WorldRaster.drawSprites(WORLD_NAME, sprites);
    console.log(`ENG10_SPRITES n=${sprites.length}`);
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

AppRegistry.registerComponent('Eng10Sprites', () => Fixture);
