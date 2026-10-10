/**
 * SC-31 image-net fixture: <Image> over http from tools/ci-image-net.sh's
 * local server (127.0.0.1:18931, 6x4 PNGs). Row 1 (y 10..70) paints images,
 * row 2 (y 80..110) is one status swatch per check: green pass, red fail.
 *   T0 x10  /red.png, stretch                       -> red
 *   T1 x80  /auth.png with header X-Token: sc31      -> green (403 without it)
 *   T2 x150 /missing.png (404), blue defaultSource   -> blue
 *   T3 x220 /yellow.png after Image.prefetch          -> yellow
 *   S0 events of T0: loadStart,load,loadEnd, source 6x4
 *   S1 events of T2: loadStart,error,loadEnd, responseCode 404
 *   S2 getSize(red)=6x4, getSizeWithHeaders(auth)=6x4, getSize(missing) rejects
 *   S3 prefetch(yellow) true, then queryCache -> only yellow is 'memory'
 * Every verdict is also logged as `SC31 <name>=<detail>`.
 */
import React from 'react';
import {AppRegistry, Image, View} from 'react-native';

const BASE = 'http://127.0.0.1:18931';
const BLUE =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGNkYPjPwMDAxMDAwMDAAAALHwEDmIWXfgAAAABJRU5ErkJggg==';
const TILE = {position: 'absolute', top: 10, width: 60, height: 60};

function useEvents(name) {
  const [log, setLog] = React.useState([]);
  const add = (ev, detail) => setLog((l) => [...l, {ev, detail}]);
  const props = {
    onLoadStart: () => add('loadStart'),
    onLoad: (e) => add('load', e.nativeEvent.source),
    onError: (e) => add('error', e.nativeEvent),
    onLoadEnd: () => add('loadEnd'),
  };
  return [log, props];
}

function Swatch({index, name, ok, detail}) {
  React.useEffect(() => {
    if (ok !== null) console.log(`SC31 ${name}=${ok ? 'pass' : 'fail'} ${detail}`);
  }, [ok, name, detail]);
  const bg = ok === null ? '#808080' : ok ? '#00ff00' : '#ff0000';
  return (
    <View
      style={{position: 'absolute', top: 80, left: 10 + index * 70, width: 60, height: 30, backgroundColor: bg}}
    />
  );
}

function Fixture() {
  const [evA, propsA] = useEvents('A');
  const [evB, propsB] = useEvents('B');
  const [sizes, setSizes] = React.useState(null);
  const [cache, setCache] = React.useState(null);
  const [showYellow, setShowYellow] = React.useState(false);

  React.useEffect(() => {
    const miss = Image.getSize(BASE + '/missing.png').then(
      () => 'resolved',
      () => 'rejected',
    );
    Promise.all([
      Image.getSize(BASE + '/red.png'),
      Image.getSizeWithHeaders(BASE + '/auth.png', {'X-Token': 'sc31'}),
      miss,
    ]).then(
      ([a, b, m]) => setSizes(`${a.width}x${a.height} ${b.width}x${b.height} ${m}`),
      (e) => setSizes('error ' + String(e && e.message)),
    );
    Image.prefetch(BASE + '/yellow.png')
      .then((ok) =>
        Image.queryCache([BASE + '/yellow.png', BASE + '/never.png']).then((q) => {
          setCache(`${ok} ${JSON.stringify(q)}`);
          setShowYellow(true);
        }),
      )
      .catch((e) => setCache('error ' + String(e && e.message)));
  }, []);

  const seq = (ev) => ev.map((x) => x.ev).join(',');
  const loadA = evA.find((x) => x.ev === 'load');
  const errB = evB.find((x) => x.ev === 'error');
  const s0 = evA.length < 3 ? null : seq(evA) === 'loadStart,load,loadEnd' && loadA.detail.width === 6 && loadA.detail.height === 4;
  const s1 = evB.length < 3 ? null : seq(evB) === 'loadStart,error,loadEnd' && errB.detail.responseCode === 404;
  const s2 = sizes === null ? null : sizes === '6x4 6x4 rejected';
  const yellowKey = JSON.stringify({[BASE + '/yellow.png']: 'memory'});
  const s3 = cache === null ? null : cache === `true ${yellowKey}`;

  return (
    <View style={{width: 440, height: 130, backgroundColor: '#202020'}}>
      <Image style={{...TILE, left: 10}} resizeMode="stretch" source={{uri: BASE + '/red.png'}} {...propsA} />
      <Image
        style={{...TILE, left: 80}}
        resizeMode="stretch"
        source={{uri: BASE + '/auth.png', headers: {'X-Token': 'sc31'}}}
      />
      <Image
        style={{...TILE, left: 150}}
        resizeMode="stretch"
        source={{uri: BASE + '/missing.png'}}
        defaultSource={{uri: BLUE}}
        {...propsB}
      />
      {showYellow ? (
        <Image style={{...TILE, left: 220}} resizeMode="stretch" source={{uri: BASE + '/yellow.png'}} />
      ) : null}
      <Swatch index={0} name="eventsLoad" ok={s0} detail={JSON.stringify(evA)} />
      <Swatch index={1} name="eventsError" ok={s1} detail={JSON.stringify(evB)} />
      <Swatch index={2} name="getSize" ok={s2} detail={String(sizes)} />
      <Swatch index={3} name="prefetchCache" ok={s3} detail={String(cache)} />
    </View>
  );
}

AppRegistry.registerComponent('probe', () => Fixture);
