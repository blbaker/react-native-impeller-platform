/**
 * parity item 15 fixture (copy of item 14's + one console.warn): app logs in the Metro terminal.
 *
 * The swatch colour lives in ./Swatch.js. The gate edits that file while the
 * app runs; Fast Refresh must repaint the swatch WITHOUT a reload (the boot
 * counter stays 1 and SWATCH_RENDER logs the new colour).
 *
 * Reload: when the launch URL has ?reload=1, the app calls
 * DevSettings.reload() 1.5 s after EVERY boot. A reload restarts the process,
 * so this repeats; the gate counts HMR_BOOT lines (>= 2 proves a reload
 * happened) and then kills the process.
 */
import React from 'react';
import {AppRegistry, DevSettings, Linking, View} from 'react-native';
import Swatch from './Swatch';

console.log('HMR_BOOT pid-start');
console.warn('METRO_LOG_WARN forwarded');

Linking.getInitialURL().then(url => {
  if (url && url.indexOf('reload=1') >= 0) {
    setTimeout(() => {
      console.log('HMR_CALLING_RELOAD');
      DevSettings.reload('gate');
    }, 1500);
  }
});

function Fixture() {
  return (
    <View style={{width: 400, height: 300, backgroundColor: '#111111'}}>
      <Swatch />
    </View>
  );
}

AppRegistry.registerComponent('Item15MetroLogs', () => Fixture);
