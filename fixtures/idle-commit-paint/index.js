/**
 * idle-commit-paint fixture: a JS commit that replaces the WHOLE screen after
 * the windowed loop has gone idle must reach the screen.
 *
 * Mac report (Jim on 0.6.0, darwin windowed, default idle-skip): "Open ticket"
 * committed the new screen (hit testing used it), but the window kept showing
 * the old one until a resize. This fixture is that shape with no input at all:
 * mount screen 0, sit idle, then swap the whole tree to another screen (new
 * key, so every node is deleted and re-created, like a navigator), several
 * times, each with a distinct full-window colour.
 *
 * Logs (one line each, read by tools/ci-idle-commit-paint.sh):
 *   ICP_READY js_ms=                 screen 0 committed
 *   ICP_SWAP n= screen= rgb= js_ms=  about to commit screen n (setState next)
 *   ICP_DONE                         last swap issued
 */
import React, {useEffect, useState} from 'react';
import {AppRegistry, Text, View} from 'react-native';

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

function Screen({index}) {
  const s = SCREENS[index % SCREENS.length];
  // A small tree, not one View: a navigator swap deletes and creates many nodes.
  return (
    <View style={{flex: 1, backgroundColor: s.bg}}>
      <View style={{height: 48, paddingHorizontal: 16, justifyContent: 'center'}}>
        <Text style={{color: '#ffffff', fontSize: 18}}>{s.name}</Text>
      </View>
      {[0, 1, 2].map(i => (
        <View
          key={i}
          style={{marginHorizontal: 16, marginTop: 8, height: 24, width: 120 + 40 * i,
                  backgroundColor: 'rgba(255,255,255,0.25)'}}
        />
      ))}
    </View>
  );
}

function App() {
  const [screen, setScreen] = useState(0);
  useEffect(() => {
    console.log('ICP_READY js_ms=' + (Date.now() - t0));
    const timers = [];
    for (let n = 1; n <= SWAPS; n++) {
      timers.push(
        setTimeout(() => {
          const s = SCREENS[n % SCREENS.length];
          console.log('ICP_SWAP n=' + n + ' screen=' + s.name + ' rgb=' + s.rgb +
                      ' js_ms=' + (Date.now() - t0));
          setScreen(n);
          if (n === SWAPS) console.log('ICP_DONE');
        }, FIRST_SWAP_MS + (n - 1) * NEXT_SWAP_MS),
      );
    }
    return () => timers.forEach(clearTimeout);
  }, []);
  return <Screen key={screen} index={screen} />;
}

AppRegistry.registerComponent('IdleCommitPaint', () => App);
