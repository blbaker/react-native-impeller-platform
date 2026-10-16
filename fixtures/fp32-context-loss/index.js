/**
 * FP-32 fixture for tools/ci-context-loss.sh (windowed, 400x300, --scale 1).
 * Every GPU-backed thing the painter caches, each in its own box so the gate
 * can address it by arithmetic:
 *   image   (10,10)   160x120  file://<dir>/photo.png (decoded once, uploaded to a texture)
 *   text    (190,10)  200x60   two lines, bold + regular (paint-thread typography context)
 *   svg     (190,80)  100x100  circle + triangle (supersample offscreen when --supersample-rnsvg > 0)
 *   world   (10,150)  200x140  <world> terrain (setPixels) + sprite atlas (registerSprite/drawSprites)
 * A counter laid out OUTSIDE the window re-renders every 200 ms, so JS keeps
 * MEASURING text (its own typography context) across the losses without
 * changing a visible pixel.
 *   fp32://run?dir=/abs/dir
 */
import React from 'react';
import {AppRegistry, Image, Linking, Text, View} from 'react-native';
import Svg, {Circle, Path} from 'react-native-svg';
import * as NativeComponentRegistry from 'react-native/Libraries/NativeComponent/NativeComponentRegistry';
import WorldRaster from '@react-native-impeller/core/src/worldraster';

const World = NativeComponentRegistry.get('world', () => ({
  uiViewClassName: 'world',
  bubblingEventTypes: {},
  directEventTypes: {},
  validAttributes: {name: true},
}));
const WORLD = 'fp32-world';
const WW = 200;
const WH = 140;

function parse(url) {
  const q = {};
  const i = url.indexOf('?');
  if (i < 0) return q;
  for (const kv of url.slice(i + 1).split('&')) {
    const eq = kv.indexOf('=');
    if (eq > 0) q[kv.slice(0, eq)] = decodeURIComponent(kv.slice(eq + 1));
  }
  return q;
}

function terrain() {
  const buf = new ArrayBuffer(WW * WH * 4);
  const b = new Uint8Array(buf);
  for (let y = 0; y < WH; y++) {
    for (let x = 0; x < WW; x++) {
      const o = (y * WW + x) * 4;
      b[o] = 40 + Math.floor((x * 120) / WW);
      b[o + 1] = 90 + ((y >> 3) & 1) * 40;
      b[o + 2] = 60;
      b[o + 3] = 255;
    }
  }
  return buf;
}

function sprite(w, h, top, bottom) {
  const buf = new ArrayBuffer(w * h * 4);
  const b = new Uint8Array(buf);
  for (let y = 0; y < h; y++) {
    const c = y < h / 2 ? top : bottom;
    for (let x = 0; x < w; x++) b.set(c, (y * w + x) * 4);
  }
  return buf;
}

function setupWorld() {
  WorldRaster.setPixels(WORLD, terrain(), WW, WH);
  WorldRaster.registerSprite('fp32-a', sprite(20, 20, [250, 220, 40, 255], [200, 40, 200, 255]), 20, 20);
  WorldRaster.registerSprite('fp32-b', sprite(16, 16, [20, 20, 240, 255], [240, 240, 240, 255]), 16, 16);
  const sprites = [];
  for (let i = 0; i < 12; i++) {
    sprites.push({textureId: i % 2 ? 'fp32-b' : 'fp32-a', x: 8 + i * 15, y: 10 + (i % 4) * 30, w: i % 2 ? 16 : 20, h: i % 2 ? 16 : 20});
  }
  WorldRaster.drawSprites(WORLD, sprites);
  console.log(`FP32 world sprites=${sprites.length}`);
}

function ContextLoss() {
  const [cfg, setCfg] = React.useState(null);
  const [tick, setTick] = React.useState(0);
  React.useEffect(() => {
    Linking.getInitialURL()
      .then((u) => setCfg(parse(u || '')))
      .catch(() => setCfg({}));
  }, []);
  React.useEffect(() => {
    if (!cfg) return undefined;
    setupWorld();
    const timer = setInterval(() => setTick((k) => k + 1), 200);
    return () => clearInterval(timer);
  }, [cfg]);
  if (!cfg) return <View style={{flex: 1, backgroundColor: '#202020'}} />;
  return (
    <View style={{flex: 1, backgroundColor: '#202020'}}>
      <Image
        source={{uri: `file://${cfg.dir}/photo.png`}}
        resizeMode="stretch"
        onLoad={() => console.log('FP32 image loaded')}
        style={{position: 'absolute', left: 10, top: 10, width: 160, height: 120}}
      />
      <View style={{position: 'absolute', left: 190, top: 10, width: 200, height: 60}}>
        <Text style={{color: '#ffffff', fontSize: 22, fontWeight: 'bold'}}>Context lost</Text>
        <Text style={{color: '#ffd040', fontSize: 16}}>FP-32 text 0123</Text>
      </View>
      <View style={{position: 'absolute', left: 190, top: 80, width: 100, height: 100}}>
        <Svg width={100} height={100} viewBox="0 0 100 100">
          <Circle cx={50} cy={50} r={45} fill="#2060ff" />
          <Path d="M50 12 L84 78 L16 78 Z" fill="#ff3020" />
        </Svg>
      </View>
      <World name={WORLD} style={{position: 'absolute', left: 10, top: 150, width: WW, height: WH}} />
      <Text style={{position: 'absolute', left: 420, top: 0, color: '#ffffff', fontSize: 12}}>
        {`tick ${tick}`}
      </Text>
    </View>
  );
}

AppRegistry.registerComponent('ContextLoss', () => ContextLoss);
