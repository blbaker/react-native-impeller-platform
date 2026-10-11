/**
 * parity item 24 fixture: a debuggable app.
 *
 * __DEBUG_FIXTURE_MARK: a value only THIS runtime has, read back over CDP
 * (Runtime.evaluate) to prove the debugger is attached to the real app.
 * __DEBUG_TICKS: bumped by a 100 ms interval; it must advance after
 * Debugger.resume (the app is running again, not stuck paused).
 */
import React from 'react';
import {AppRegistry, Text, View} from 'react-native';

globalThis.__DEBUG_FIXTURE_MARK = 'impeller-debuggee-' + (6 * 7);
globalThis.__DEBUG_TICKS = 0;
setInterval(() => {
  globalThis.__DEBUG_TICKS += 1;
}, 100);
console.log('DEBUG_FIXTURE_BOOT');

function Fixture() {
  return (
    <View style={{flex: 1, backgroundColor: '#204080'}}>
      <Text style={{color: 'white'}}>debug me</Text>
    </View>
  );
}

AppRegistry.registerComponent('Item24Debugger', () => Fixture);
