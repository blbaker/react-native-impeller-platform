/**
 * ENG-10 world-sprites gate — REFERENCE FIXTURE (the oracle).
 *
 * The IDENTICAL scene (same terrain, same atlas, same back-to-front list from
 * ./scene), composited on the CPU and published as ONE buffer through the
 * proven ENG-09 setPixels path. No drawSprites call. The gate requires the GPU
 * render (index.js) to match this per-pixel.
 */
import React from 'react';
import {AppRegistry, View} from 'react-native';
import * as NativeComponentRegistry from 'react-native/Libraries/NativeComponent/NativeComponentRegistry';
import WorldRaster from '@react-native-impeller/core/src/worldraster';
import {WIDTH, HEIGHT, buildSprites, compositeOnCpu} from './scene';

const World = NativeComponentRegistry.get('world', () => ({
  uiViewClassName: 'world',
  bubblingEventTypes: {},
  directEventTypes: {},
  validAttributes: {name: true},
}));
const WORLD_NAME = 'eng10-gate-reference';

function Reference() {
  React.useEffect(() => {
    WorldRaster.setPixels(WORLD_NAME, compositeOnCpu(buildSprites()), WIDTH, HEIGHT);
    console.log('ENG10_REFERENCE composited');
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

AppRegistry.registerComponent('Eng10SpritesReference', () => Reference);
