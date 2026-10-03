/**
 * first-present fixture: a launch animation that must be VISIBLE.
 *
 * Shape of the HostApp v5 boot (Mac report, 2026-10-03): JS starts a boot clock
 * with requestAnimationFrame, animates a mark for ~1.5 s, then swaps to the
 * Home screen. On the old windowed boot the first present landed AFTER the
 * clock finished, so the mark was never on screen.
 *
 * Screens:
 *   BOOT  full-window red (#ff0000) with a green square that slides right.
 *   HOME  full-window blue (#0000ff).
 * The gate reads which screen the FIRST presented frame showed.
 *
 * Logs (one line each, read by tools/ci-first-present.sh):
 *   FP_JS_START        module evaluation (the moment JS starts)
 *   FP_CLOCK_START     the first rAF tick of the boot clock
 *   FP_CLOCK_DONE ms=  the boot clock finished; HOME is rendered next
 *   FP_FIRST_FRAME     the host's firstFramePresented event arrived (if any)
 */
import React, {useEffect, useState} from 'react';
import {AppRegistry, DeviceEventEmitter, View} from 'react-native';

const BOOT_MS = 1500;
const t0 = Date.now();
console.log('FP_JS_START');

let firstFrameSeen = false;
DeviceEventEmitter.addListener('firstFramePresented', () => {
  if (firstFrameSeen) return;
  firstFrameSeen = true;
  console.log('FP_FIRST_FRAME js_ms=' + (Date.now() - t0));
});

function App() {
  const [x, setX] = useState(0);
  const [done, setDone] = useState(false);
  useEffect(() => {
    let start = -1;
    let id = 0;
    const tick = now => {
      if (start < 0) {
        start = now;
        console.log('FP_CLOCK_START js_ms=' + (Date.now() - t0));
      }
      const el = now - start;
      if (el >= BOOT_MS) {
        console.log('FP_CLOCK_DONE ms=' + Math.round(el) + ' js_ms=' + (Date.now() - t0));
        setDone(true);
        return;
      }
      setX(Math.round((el / BOOT_MS) * 200));
      id = requestAnimationFrame(tick);
    };
    id = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(id);
  }, []);
  if (done) {
    return <View style={{flex: 1, backgroundColor: '#0000ff'}} />;
  }
  return (
    <View style={{flex: 1, backgroundColor: '#ff0000'}}>
      <View
        style={{
          position: 'absolute',
          left: 20 + x,
          top: 40,
          width: 60,
          height: 60,
          backgroundColor: '#00ff00',
        }}
      />
    </View>
  );
}

AppRegistry.registerComponent('FirstPresent', () => App);
