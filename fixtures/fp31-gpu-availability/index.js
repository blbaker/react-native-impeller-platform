/**
 * FP-31 fixture for tools/ci-gpu-availability.sh (windowed, 400x300).
 * GpuAvailability: JS state keeps changing while the engine's GPU is switched
 * off. A 160x160 centre box shows the tick as its red channel (tick * 8), so a
 * frame read back from the screen says which JS state it shows. Every 2nd tick
 * also mounts one more 14x14 image (file://<dir>/img-<i>.png) on the box's top
 * edge, so decode + texture upload are requested while the GPU is off. All the
 * damage stays inside the box (under 70% of each side), so a restore that
 * painted only the damage would be a partial repaint.
 * Ticks stop at `ticks` (default 25): after that JS is idle, which is what
 * lets the gate see whether the restore repaints by itself.
 *   fp31://run?dir=/abs/dir&ticks=25&intervalMs=100&images=10
 */
import React from 'react';
import {AppRegistry, AppState, Image, Linking, View} from 'react-native';

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

function GpuAvailability() {
  const [cfg, setCfg] = React.useState(null);
  const [tick, setTick] = React.useState(0);
  React.useEffect(() => {
    Linking.getInitialURL()
      .then((u) => setCfg(parse(u || '')))
      .catch(() => setCfg({}));
    const sub = AppState.addEventListener('change', (s) => console.log(`FP31 appstate=${s}`));
    return () => sub.remove();
  }, []);
  React.useEffect(() => {
    if (!cfg) return undefined;
    const ticks = Number(cfg.ticks || 25);
    const timer = setInterval(() => {
      setTick((k) => {
        const n = Math.min(k + 1, ticks);
        if (n === k) {
          clearInterval(timer);
          return k;
        }
        console.log(`FP31 tick=${n}`);
        return n;
      });
    }, Number(cfg.intervalMs || 100));
    return () => clearInterval(timer);
  }, [cfg]);
  if (!cfg) return <View style={{flex: 1, backgroundColor: '#000'}} />;
  const images = Math.min(Number(cfg.images || 0), Math.floor(tick / 2));
  const tiles = [];
  for (let i = 0; i < images; i++) {
    tiles.push(
      <Image
        key={i}
        source={{uri: `file://${cfg.dir}/img-${i}.png`}}
        resizeMode="stretch"
        style={{position: 'absolute', left: 124 + i * 15, top: 74, width: 14, height: 14}}
      />,
    );
  }
  return (
    <View style={{flex: 1, backgroundColor: '#000'}}>
      <View
        style={{
          position: 'absolute',
          left: 120,
          top: 70,
          width: 160,
          height: 160,
          backgroundColor: `rgb(${tick * 8}, 0, 0)`,
        }}
      />
      {tiles}
    </View>
  );
}

AppRegistry.registerComponent('GpuAvailability', () => GpuAvailability);
