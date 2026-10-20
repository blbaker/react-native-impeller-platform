/**
 * idle-commit-paint fixture: a JS commit that replaces the WHOLE screen after
 * the windowed loop has gone idle must reach the screen.
 *
 * Mac report (Jim on 0.6.0, darwin windowed, default idle-skip): "Open ticket"
 * committed the new screen (hit testing used it), but the window kept showing
 * the old one until a resize. This fixture is that shape: mount screen 0, sit
 * idle, then swap the whole tree to another screen (new key, so every node is
 * deleted and re-created, like a navigator), several times, each with a
 * distinct full-window colour.
 *
 * Modes, from --initial-url (one committed bundle serves every arm):
 *   icp://swap            timers only (default; no input at all)
 *   icp://swap?heavy=1    each screen is ~250 nodes of text rows, like a real
 *                         dashboard -> ticket swap (bigger commit, longer RECORD)
 *   icp://swap?click=1    ONE swap, made by the onPress of a full-window
 *                         Pressable (the "Open ticket" click), no timers
 *
 * Logs (one line each, read by tools/ci-idle-commit-paint.sh):
 *   ICP_READY mode= js_ms=           screen 0 committed
 *   ICP_SWAP n= screen= rgb= js_ms=  about to commit screen n (setState next)
 *   ICP_DONE                         last swap issued
 */
import React, {useEffect, useState} from 'react';
import {AppRegistry, Linking, Pressable, Text, View} from 'react-native';

// Full-window backgrounds, far apart in RGB so a stale frame cannot pass.
const SCREENS = [
  {name: 'dashboard', bg: '#1e4fd8', rgb: '30,79,216'},
  {name: 'overview', bg: '#e8590c', rgb: '232,89,12'},
  {name: 'activity', bg: '#2f9e44', rgb: '47,158,68'},
  {name: 'settings', bg: '#ae3ec9', rgb: '174,62,201'},
];
const FIRST_SWAP_MS = 2000; // the loop is parked long before this
const NEXT_SWAP_MS = 1500;
const SWAPS = 4;
const t0 = Date.now();

function parseMode(url) {
  const q = (url || '').split('?')[1] || '';
  const has = k => q.split('&').some(p => p === k + '=1');
  return {heavy: has('heavy'), click: has('click')};
}

function Rows({index}) {
  // ~60 rows x (row + 3 texts): a navigator-sized commit, mostly background.
  const rows = [];
  for (let i = 0; i < 60; i++) {
    rows.push(
      <View key={i} style={{flexDirection: 'row', height: 18, paddingHorizontal: 16}}>
        <Text style={{color: '#ffffff', fontSize: 9, width: 90}}>{'TASK-' + (index * 100 + i)}</Text>
        <Text style={{color: '#ffffff', fontSize: 9, width: 160}}>{'row ' + i + ' of screen ' + index}</Text>
        <Text style={{color: '#ffffff', fontSize: 9}}>{i % 3 === 0 ? 'open' : 'done'}</Text>
      </View>,
    );
  }
  return rows;
}

function Screen({index, heavy}) {
  const s = SCREENS[index % SCREENS.length];
  // A small tree, not one View: a navigator swap deletes and creates many nodes.
  return (
    <View style={{flex: 1, backgroundColor: s.bg}}>
      <View style={{height: 48, paddingHorizontal: 16, justifyContent: 'center'}}>
        <Text style={{color: '#ffffff', fontSize: 18}}>{s.name}</Text>
      </View>
      {heavy ? (
        <Rows index={index} />
      ) : (
        [0, 1, 2].map(i => (
          <View
            key={i}
            style={{marginHorizontal: 16, marginTop: 8, height: 24, width: 120 + 40 * i,
                    backgroundColor: 'rgba(255,255,255,0.25)'}}
          />
        ))
      )}
    </View>
  );
}

function App() {
  const [mode, setMode] = useState(null);
  const [screen, setScreen] = useState(0);

  useEffect(() => {
    Linking.getInitialURL()
      .then(url => setMode(parseMode(url)))
      .catch(() => setMode(parseMode('')));
  }, []);

  const swap = n => {
    const s = SCREENS[n % SCREENS.length];
    console.log('ICP_SWAP n=' + n + ' screen=' + s.name + ' rgb=' + s.rgb +
                ' js_ms=' + (Date.now() - t0));
    setScreen(n);
    if (n === SWAPS || (mode && mode.click)) console.log('ICP_DONE');
  };

  useEffect(() => {
    if (!mode) return undefined;
    console.log('ICP_READY mode=' + (mode.heavy ? 'heavy' : 'light') +
                (mode.click ? '+click' : '') + ' js_ms=' + (Date.now() - t0));
    // click=1: ONE swap, the press itself, and no timers at all, so a test
    // hand that waits for JS idle after the click is not held off by them.
    if (mode.click) return undefined;
    const timers = [];
    for (let n = 1; n <= SWAPS; n++) {
      timers.push(setTimeout(() => swap(n), FIRST_SWAP_MS + (n - 1) * NEXT_SWAP_MS));
    }
    return () => timers.forEach(clearTimeout);
  }, [mode]);

  if (!mode) return <View style={{flex: 1, backgroundColor: SCREENS[0].bg}} />;
  const body = <Screen key={screen} index={screen} heavy={mode.heavy} />;
  if (mode.click && screen === 0) {
    return (
      <Pressable style={{flex: 1}} onPress={() => swap(1)}>
        {body}
      </Pressable>
    );
  }
  return body;
}

AppRegistry.registerComponent('IdleCommitPaint', () => App);
