// FP-44 fixture: <ImpellerPlatformView> (a native child view) inside a scroll view.
//
// Layout (400x300 window, scale 1), window pixels:
//   header    (0,0) 400x40 grey; a 20x20 tick box at (10,10) flips colour every
//             step during the holds (frames keep presenting, the view must stay)
//   viewport  ScrollView (50,60) 300x200, white, content 300x800
//   group     content (40,100) 200x80, transform translateX(tx) [rotate]
//     hole    magenta 160x80 at group (0,0), painted BEFORE the view: the
//             probe's marker for where RN says the native view is
//     view    ImpellerPlatformView 160x80 at group (0,0), color #00aa00
//     above   yellow 80x30 at group (110,30), painted AFTER the view, overlaps it
// Timeline (step = `step` ms), each phase logged as `FP44 phase=<name>`:
//   boot    `boot` ms, nothing changes
//   holdA   scroll 0, tx 0         view (90,160)-(250,240)
//   scroll  0 -> 140 by 7          the viewport clips the view's top at y=60
//   holdB   scroll 140             view (90,20)-(250,100), visible (90,60)-(250,100)
//   move    tx 0 -> 180 by 9
//   holdC   tx 180                 view (270,20)-(430,100), visible (270,60)-(350,100)
//   rotate  rotate 10deg (unsupported: logged once, placed at the bounding box)
//   done
// Initial URL: fp44://run?step=50&hold=1000&boot=800
import React, {useEffect, useRef, useState} from 'react';
import {AppRegistry, Linking, ScrollView, View, processColor} from 'react-native';
import * as NativeComponentRegistry from 'react-native/Libraries/NativeComponent/NativeComponentRegistry';

const PlatformView = NativeComponentRegistry.get('ImpellerPlatformView', () => ({
  uiViewClassName: 'ImpellerPlatformView',
  bubblingEventTypes: {},
  directEventTypes: {},
  validAttributes: {color: {process: processColor}},
}));

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

function PlatformViewApp() {
  const scroll = useRef(null);
  const [tx, setTx] = useState(0);
  const [rot, setRot] = useState(0);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let timer = null;
    let alive = true;
    Linking.getInitialURL().then((u) => {
      const q = parse(u || '');
      const step = Number(q.step || 50);
      const hold = Number(q.hold || 700);
      const holdSteps = () => {
        const out = [];
        for (let t = 0; t < hold; t += step) out.push(['tick', 0], ['wait', step]);
        return out;
      };
      // boot: the first frames after mount are slow on a loaded box; hold A starts after.
      const plan = [['phase', 'boot'], ['wait', Number(q.boot || 800)], ['phase', 'holdA'],
        ...holdSteps(), ['phase', 'scroll']];
      for (let y = 7; y <= 140; y += 7) plan.push(['scroll', y], ['wait', step]);
      plan.push(['phase', 'holdB'], ...holdSteps(), ['phase', 'move']);
      for (let x = 9; x <= 180; x += 9) plan.push(['tx', x], ['wait', step]);
      plan.push(['phase', 'holdC'], ...holdSteps(), ['phase', 'rotate'], ['rot', 10],
        ...holdSteps(), ['phase', 'done']);
      let i = 0;
      const next = () => {
        while (alive && i < plan.length) {
          const [op, v] = plan[i++];
          if (op === 'wait') {
            timer = setTimeout(next, v);
            return;
          }
          if (op === 'phase') console.log(`FP44 phase=${v}`);
          if (op === 'scroll') scroll.current && scroll.current.scrollTo({y: v, animated: false});
          if (op === 'tx') setTx(v);
          if (op === 'rot') setRot(v);
          if (op === 'tick') setTick((t) => t + 1);
        }
      };
      next();
    });
    return () => {
      alive = false;
      timer && clearTimeout(timer);
    };
  }, []);
  const transform = rot ? [{translateX: tx}, {rotate: `${rot}deg`}] : [{translateX: tx}];
  return (
    <View style={{flex: 1, backgroundColor: '#ffffff'}}>
      <View style={{position: 'absolute', left: 0, top: 0, width: 400, height: 40,
        backgroundColor: '#808080'}} />
      <View style={{position: 'absolute', left: 10, top: 10, width: 20, height: 20,
        backgroundColor: tick % 2 ? '#000080' : '#008080'}} />
      <ScrollView
        ref={scroll}
        showsVerticalScrollIndicator={false}
        showsHorizontalScrollIndicator={false}
        style={{position: 'absolute', left: 50, top: 60, width: 300, height: 200,
          backgroundColor: '#ffffff'}}>
        <View style={{width: 300, height: 800}}>
          <View style={{position: 'absolute', left: 40, top: 100, width: 200, height: 80,
            transform}}>
            <View style={{position: 'absolute', left: 0, top: 0, width: 160, height: 80,
              backgroundColor: '#ff00ff'}} />
            <PlatformView color="#00aa00"
              style={{position: 'absolute', left: 0, top: 0, width: 160, height: 80}} />
            <View style={{position: 'absolute', left: 110, top: 30, width: 80, height: 30,
              backgroundColor: '#ffff00'}} />
          </View>
        </View>
      </ScrollView>
    </View>
  );
}

AppRegistry.registerComponent('PlatformView', () => PlatformViewApp);
