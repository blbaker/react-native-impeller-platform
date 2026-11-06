/**
 * RN-core fixture.
 * One committed bundle; the route comes from the initial URL:
 *   rncore://image?mode=cover|contain|stretch   require()d PNG (row 2)
 *   rncore://ws?port=N&text=hello               global WebSocket echo (row 4)
 *   rncore://anim?ms=300                        Animated.timing, JS driver (row 6)
 *
 * Image route, 400 x 300 white surface:
 *   A  the card PNG at its natural 120 x 168, top-left (10, 10)
 *   B  a 200 x 100 grey box at (150, 10) holding the same PNG at 200 x 100
 *      with resizeMode from the URL. Grey shows wherever the image does not.
 * card.png is three bands top to bottom: red, green, blue (56 rows each).
 */
import React from 'react';
import {AppRegistry, Animated, Easing, Image, Linking, Text, TurboModuleRegistry, View} from 'react-native';

import VideoRoute from './VideoRoute';

const CARD = require('./card.png');

function parse(url) {
  const q = {route: ''};
  const m = /^[a-z0-9]+:\/\/([^?]*)/.exec(url || '');
  if (m) q.route = m[1];
  const i = (url || '').indexOf('?');
  if (i < 0) return q;
  for (const kv of url.slice(i + 1).split('&')) {
    const eq = kv.indexOf('=');
    if (eq > 0) q[kv.slice(0, eq)] = decodeURIComponent(kv.slice(eq + 1));
  }
  return q;
}

function ImageRoute({cfg}) {
  const mode = cfg.mode || 'cover';
  const src = Image.resolveAssetSource(CARD);
  console.log(`RNCORE_IMAGE source uri=${src && src.uri} w=${src && src.width} h=${src && src.height}`);
  const ev = (tag) => ({
    onLoad: (e) => {
      const s = (e && e.nativeEvent && e.nativeEvent.source) || {};
      console.log(`RNCORE_IMAGE onLoad ${tag} w=${s.width} h=${s.height}`);
    },
    onError: (e) => console.log(`RNCORE_IMAGE onError ${tag} ${JSON.stringify(e && e.nativeEvent)}`),
  });
  return (
    <View style={{flex: 1, backgroundColor: 'white'}}>
      <Image
        source={CARD}
        {...ev('natural')}
        style={{position: 'absolute', left: 10, top: 10, width: 120, height: 168}}
      />
      <View
        style={{
          position: 'absolute',
          left: 150,
          top: 10,
          width: 200,
          height: 100,
          backgroundColor: 'rgb(128, 128, 128)',
        }}>
        <Image source={CARD} resizeMode={mode} {...ev(mode)} style={{width: 200, height: 100}} />
      </View>
      {/* C: a playing-card-back shape: a sized card View
          whose Image is stretch at width/height '100%'. 60 x 84 at (150, 120). */}
      <View
        style={{
          position: 'absolute',
          left: 150,
          top: 120,
          width: 60,
          height: 84,
          backgroundColor: 'rgb(128, 128, 128)',
        }}>
        <Image source={CARD} resizeMode="stretch" {...ev('percent')} style={{width: '100%', height: '100%'}} />
      </View>
    </View>
  );
}

function WsRoute({cfg}) {
  const [line, setLine] = React.useState('connecting');
  React.useEffect(() => {
    const url = `ws://127.0.0.1:${cfg.port}/echo`;
    const text = cfg.text || 'hello-rncore';
    console.log(`RNCORE_WS typeof=${typeof WebSocket} url=${url}`);
    const ws = new WebSocket(url);
    const burst = Number(cfg.burst || 20);
    let got = 0;
    let inOrder = true;
    ws.onopen = () => {
      console.log(`RNCORE_WS open readyState=${ws.readyState}`);
      ws.send(text);
    };
    ws.onmessage = (e) => {
      if (got === 0) {
        console.log(`RNCORE_WS message data=${e.data}`);
        setLine(`echo:${e.data}`);
        // Then a burst, the shape of a hardware event stream: N ordered JSON frames.
        for (let i = 0; i < burst; i++) ws.send(JSON.stringify({seq: i, speed: i / 10}));
      } else {
        const seq = JSON.parse(e.data).seq;
        if (seq !== got - 1) inOrder = false;
      }
      got += 1;
      if (got === burst + 1) {
        console.log(`RNCORE_WS burst received=${got - 1} inOrder=${inOrder}`);
        ws.close(1000, 'done');
      }
    };
    ws.onerror = (e) => console.log(`RNCORE_WS error ${e && e.message}`);
    ws.onclose = (e) => {
      console.log(`RNCORE_WS close code=${e.code} reason=${e.reason}`);
      setLine((l) => `${l} closed:${e.code}`);
    };
    return () => ws.close();
  }, [cfg]);
  return (
    <View style={{flex: 1, backgroundColor: 'white', padding: 20}}>
      <Text style={{fontSize: 20, color: 'black'}}>{line}</Text>
    </View>
  );
}

function AnimRoute({cfg}) {
  const ms = Number(cfg.ms || 300);
  const shots = (cfg.shots || '0,150,300').split(',').map(Number);
  const v = React.useRef(new Animated.Value(0)).current;
  React.useEffect(() => {
    let t0 = 0;
    const id = v.addListener(({value}) =>
      console.log(`RNCORE_ANIM tick t=${Date.now() - t0} value=${value.toFixed(3)}`),
    );
    const shot = TurboModuleRegistry.get('RNViewShot');
    // Capture the screen at fixed offsets from the animation start, on the
    // animation's own clock (captureScreen renders the mounted tree).
    const capture = (at) => {
      const req = Date.now() - t0;
      const val = v.__getValue();
      if (shot == null) {
        console.log(`RNCORE_ANIM shot at=${at} ERROR no RNViewShot module`);
        return;
      }
      shot
        .captureScreen({format: 'png', result: 'tmpfile', quality: 1, fileName: `rncore-anim-${at}`})
        .then((uri) =>
          console.log(`RNCORE_ANIM shot at=${at} req=${req} value=${val.toFixed(3)} uri=${uri}`),
        )
        .catch((e) => console.log(`RNCORE_ANIM shot at=${at} ERROR ${e && e.message}`));
    };
    const startT = setTimeout(() => {
      t0 = Date.now();
      console.log('RNCORE_ANIM start');
      Animated.timing(v, {
        toValue: 1,
        duration: ms,
        easing: Easing.linear,
        useNativeDriver: false,
      }).start(({finished}) => console.log(`RNCORE_ANIM done finished=${finished} t=${Date.now() - t0}`));
      for (const at of shots) {
        if (at === 0) capture(0);
        else setTimeout(() => capture(at), at);
      }
    }, Number(cfg.delay || 500));
    return () => {
      clearTimeout(startT);
      v.removeListener(id);
    };
  }, [ms, v]);
  const tx = v.interpolate({inputRange: [0, 1], outputRange: [0, 100]});
  return (
    <View style={{flex: 1, backgroundColor: 'black'}}>
      <Animated.View
        style={{
          position: 'absolute',
          left: 20,
          top: 20,
          width: 100,
          height: 100,
          backgroundColor: 'rgb(0, 255, 0)',
          opacity: v,
        }}
      />
      <Animated.View
        style={{
          position: 'absolute',
          left: 20,
          top: 160,
          width: 60,
          height: 60,
          backgroundColor: 'rgb(255, 255, 255)',
          transform: [{translateX: tx}],
        }}
      />
    </View>
  );
}

function BlurRoute({cfg}) {
  // Row 5, filter style: a 200 x 100 box at (40, 40) whose content is a hard
  // black | white edge at x = 140, with RN's `filter: [{blur: 6}]` when on=1.
  const on = cfg.on === '1';
  console.log(`RNCORE_BLUR on=${on}`);
  return (
    <View style={{flex: 1, backgroundColor: 'rgb(128, 128, 128)'}}>
      <View
        style={{
          position: 'absolute',
          left: 40,
          top: 40,
          width: 200,
          height: 100,
          flexDirection: 'row',
          filter: on ? [{blur: 6}] : undefined,
        }}>
        <View style={{width: 100, height: 100, backgroundColor: 'black'}} />
        <View style={{width: 100, height: 100, backgroundColor: 'white'}} />
      </View>
    </View>
  );
}

function RnCore() {
  const [cfg, setCfg] = React.useState(null);
  React.useEffect(() => {
    Linking.getInitialURL()
      .then((u) => setCfg(parse(u || '')))
      .catch(() => setCfg({route: ''}));
  }, []);
  if (!cfg) return <View style={{flex: 1, backgroundColor: 'white'}} />;
  console.log(`RNCORE route=${cfg.route}`);
  if (cfg.route === 'image') return <ImageRoute cfg={cfg} />;
  if (cfg.route === 'ws') return <WsRoute cfg={cfg} />;
  if (cfg.route === 'anim') return <AnimRoute cfg={cfg} />;
  if (cfg.route === 'blur') return <BlurRoute cfg={cfg} />;
  if (cfg.route === 'video') return <VideoRoute cfg={cfg} />;
  return <View style={{flex: 1, backgroundColor: 'white'}} />;
}

AppRegistry.registerComponent('RnCore', () => RnCore);
