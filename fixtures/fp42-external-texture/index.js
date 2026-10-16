// FP-42 fixture: <ImpellerTextureView> fed by a native test producer.
//
// Layout (400x300 window, scale 1):
//   clip     (40,40) 240x120, overflow hidden, white
//   texture  (60,40) 160x160 inside it: rotate 90deg, opacity 0.6 -> its bottom
//            40 px (y 160..200) are clipped away
// The producer (ImpellerTextureRegistry.registerTestProducer) paints a 64x64
// frame k at `fps`: top-left quadrant blue, the rest R=(k%32)*8, G=(k/32%32)*8.
// The producer stops after `frames` frames (still registered); after
// `unregisterMs` the texture is unregistered and the view stays mounted, so the
// only thing that can repaint it then is the unregister itself.
// Initial URL: fp42://run?fps=30&frames=75&unregisterMs=3017
import React, {useEffect, useState} from 'react';
import {AppRegistry, Linking, TurboModuleRegistry, View} from 'react-native';
import * as NativeComponentRegistry from 'react-native/Libraries/NativeComponent/NativeComponentRegistry';

const TextureView = NativeComponentRegistry.get('ImpellerTextureView', () => ({
  uiViewClassName: 'ImpellerTextureView',
  bubblingEventTypes: {},
  directEventTypes: {},
  validAttributes: {textureId: true},
}));
const Registry = TurboModuleRegistry.get('ImpellerTextureRegistry');

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

function ExternalTexture() {
  const [id, setId] = useState(0);
  useEffect(() => {
    let timer = null;
    Linking.getInitialURL().then((u) => {
      const q = parse(u || '');
      if (Registry == null || !Registry.isSupported()) {
        console.log('FP42 no ImpellerTextureRegistry module');
        return;
      }
      const tid = Registry.registerTestProducer(Number(q.fps || 30), 64, 64, Number(q.frames || 0));
      console.log(`FP42 registered id=${tid}`);
      setId(tid);
      timer = setTimeout(() => {
        const ok = Registry.unregister(tid);
        console.log(`FP42 unregistered id=${tid} ok=${ok}`);
      }, Number(q.unregisterMs || 3000));
    });
    return () => timer && clearTimeout(timer);
  }, []);
  return (
    <View style={{flex: 1, backgroundColor: '#ffffff'}}>
      <View
        style={{position: 'absolute', left: 40, top: 40, width: 240, height: 120,
          overflow: 'hidden', backgroundColor: '#ffffff'}}>
        {id > 0 ? (
          <TextureView
            textureId={id}
            style={{position: 'absolute', left: 20, top: 0, width: 160, height: 160,
              opacity: 0.6, transform: [{rotate: '90deg'}]}}
          />
        ) : null}
      </View>
    </View>
  );
}

AppRegistry.registerComponent('ExternalTexture', () => ExternalTexture);
