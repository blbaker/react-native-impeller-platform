/**
 * FP-16 image-io fixture (tools/ci-image-io.sh). Everything comes from the
 * initial URL, so one committed bundle serves every arm:
 *   fp16://show?dir=/abs/dir&count=200&box=20&cols=20         img-0.png .. img-199.png
 *   fp16://show?dir=/abs/dir&names=a.png,b.png&box=100        named files
 *   ...&unmountMs=30                                           unmount them all after 30 ms
 *   ...&gap=4&mode=cover                                       spacing, resizeMode
 * A name may repeat (same file in several boxes).
 * Images are file:// sources laid out on a grid of box x box points.
 */
import React from 'react';
import {AppRegistry, Image, Linking, View} from 'react-native';

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

function Probe() {
  const [cfg, setCfg] = React.useState(null);
  const [show, setShow] = React.useState(true);
  React.useEffect(() => {
    Linking.getInitialURL()
      .then((u) => setCfg(parse(u || '')))
      .catch(() => setCfg({}));
  }, []);
  React.useEffect(() => {
    if (!cfg || !cfg.unmountMs) return undefined;
    const t = setTimeout(() => {
      setShow(false);
      console.log('FP16 unmounted');
    }, Number(cfg.unmountMs));
    return () => clearTimeout(t);
  }, [cfg]);
  if (!cfg) return <View style={{flex: 1, backgroundColor: 'white'}} />;
  const names = cfg.names
    ? cfg.names.split(',')
    : Array.from({length: Number(cfg.count || 0)}, (_, i) => `img-${i}.png`);
  const box = Number(cfg.box || 20);
  const gap = Number(cfg.gap || 0);
  const cols = Number(cfg.cols || 20);
  console.log(`FP16 images=${show ? names.length : 0}`);
  return (
    <View style={{flex: 1, backgroundColor: 'white'}}>
      {show &&
        names.map((n, i) => (
          <Image
            key={`${i}-${n}`}
            source={{uri: `file://${cfg.dir}/${n}`}}
            resizeMode={cfg.mode || 'stretch'}
            style={{
              position: 'absolute',
              left: (i % cols) * (box + gap),
              top: Math.floor(i / cols) * (box + gap),
              width: box,
              height: box,
            }}
          />
        ))}
    </View>
  );
}

AppRegistry.registerComponent('Fp16ImageIo', () => Probe);
