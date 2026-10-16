/**
 * FP-17 image-upload fixture (tools/ci-image-upload.sh). Large images arrive one
 * by one while a native-driver animation keeps frames flowing. Everything comes
 * from the initial URL, so one committed bundle serves every arm:
 *   fp17://run?dir=/abs/dir&count=30&startMs=1200&intervalMs=80&box=1000
 *   ...&noimg=1   grey Views in the same places, no images
 *   ...&preload=1 the control: the same 30 images are first mounted 1 px wide in
 *                 a corner (decoded, uploaded and painted once), unmounted at
 *                 startMs - 150, then the tiles arrive exactly as in the main
 *                 arm but hit the decode cache and the painter's textures: the
 *                 same frames and draws with no decode or upload in them.
 * warm.png (any small image) is painted from the start in every arm, so the
 * first textured draw (Impeller builds the texture pipeline lazily) happens
 * before the measured window. img-<i>.png sits in tile i of a 6-column grid of 100 pt tiles. Each image is
 * laid out at box x box points (so it decodes and uploads at that size) and
 * scaled down to `paint` pt (default 30) by a transform, so painting it costs
 * little and the control's raster time stays comparable.
 */
import React from 'react';
import {Animated, AppRegistry, Easing, Image, Linking, View} from 'react-native';

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

function Spinner() {
  const v = React.useRef(new Animated.Value(0)).current;
  React.useEffect(() => {
    const loop = Animated.loop(
      Animated.timing(v, {toValue: 1, duration: 700, easing: Easing.linear, useNativeDriver: true}),
    );
    loop.start();
    return () => loop.stop();
  }, [v]);
  const rotate = v.interpolate({inputRange: [0, 1], outputRange: ['0deg', '360deg']});
  return (
    <Animated.View
      style={{
        position: 'absolute',
        left: 250,
        top: 520,
        width: 100,
        height: 20,
        backgroundColor: '#fff',
        transform: [{rotate}],
      }}
    />
  );
}

function Probe() {
  const [cfg, setCfg] = React.useState(null);
  const [n, setN] = React.useState(0);
  const [pre, setPre] = React.useState(true);
  React.useEffect(() => {
    Linking.getInitialURL()
      .then((u) => setCfg(parse(u || '')))
      .catch(() => setCfg({}));
  }, []);
  React.useEffect(() => {
    if (!cfg) return undefined;
    const count = Number(cfg.count || 0);
    let timer = null;
    const drop = setTimeout(() => setPre(false), Math.max(0, Number(cfg.startMs || 1200) - 150));
    const start = setTimeout(() => {
      timer = setInterval(() => {
        setN((k) => {
          if (k + 1 >= count) clearInterval(timer);
          console.log(`FP17 mounted=${Math.min(k + 1, count)}`);
          return Math.min(k + 1, count);
        });
      }, Number(cfg.intervalMs || 80));
    }, Number(cfg.startMs || 1200));
    return () => {
      clearTimeout(start);
      clearTimeout(drop);
      if (timer) clearInterval(timer);
    };
  }, [cfg]);
  if (!cfg) return <View style={{flex: 1, backgroundColor: '#000'}} />;
  const box = Number(cfg.box || 1000);
  const s = Number(cfg.paint || 30) / box;
  const tiles = [];
  for (let i = 0; i < n; i++) {
    const cx = (i % 6) * 100 + 50;
    const cy = Math.floor(i / 6) * 100 + 50;
    const style = {
      position: 'absolute',
      left: cx - box / 2,
      top: cy - box / 2,
      width: box,
      height: box,
      transform: [{scale: s}],
    };
    tiles.push(
      cfg.noimg === '1' ? (
        <View key={i} style={[style, {backgroundColor: '#808080'}]} />
      ) : (
        <Image key={i} source={{uri: `file://${cfg.dir}/img-${i}.png`}} resizeMode="stretch" style={style} />
      ),
    );
  }
  const count = Number(cfg.count || 0);
  const preload = [];
  for (let i = 0; cfg.preload === '1' && pre && i < count; i++) {
    preload.push(
      <Image
        key={`p${i}`}
        source={{uri: `file://${cfg.dir}/img-${i}.png`}}
        resizeMode="stretch"
        style={{
          position: 'absolute',
          left: 590 - box / 2,
          top: 550 - box / 2,
          width: box,
          height: box,
          transform: [{scale: 1 / box}],
        }}
      />,
    );
  }
  return (
    <View style={{flex: 1, backgroundColor: '#000'}}>
      {cfg.noimg !== '1' && (
        <Image
          source={{uri: `file://${cfg.dir}/warm.png`}}
          style={{position: 'absolute', left: 560, top: 520, width: 20, height: 20}}
        />
      )}
      {preload}
      {tiles}
      <Spinner />
    </View>
  );
}

AppRegistry.registerComponent('Fp17ImageUpload', () => Probe);
