/**
 * Exit-race stress fixture: the JS thread is ALWAYS mid-render.
 *
 * A 0 ms interval bumps state forever, so every RuntimeScheduler tick ends in
 * updateRendering(), which reads the Scheduler's event-timing delegate
 * (EventPerformanceLogger). If the host destroys the Scheduler while such a
 * tick is in flight, that tick calls into a freed logger: SIGSEGV on exit.
 * The fixture also presses (onPressIn) so event-timing entries exist.
 */
import React, {useEffect, useState} from 'react';
import {AppRegistry, Pressable, Text, View} from 'react-native';

function Churn() {
  const [n, setN] = useState(0);
  useEffect(() => {
    const id = setInterval(() => setN(v => v + 1), 0);
    return () => clearInterval(id);
  }, []);
  const cells = [];
  for (let i = 0; i < 24; i++) {
    cells.push(
      <View
        key={i}
        style={{
          width: 40,
          height: 20,
          margin: 2,
          backgroundColor: (n + i) % 2 ? '#3355ff' : '#ff5533',
        }}
      />,
    );
  }
  return (
    <Pressable onPressIn={() => setN(v => v + 7)} style={{flex: 1}}>
      <View style={{flexDirection: 'row', flexWrap: 'wrap'}}>{cells}</View>
      <Text>{'tick ' + n}</Text>
    </Pressable>
  );
}

AppRegistry.registerComponent('ExitRace', () => Churn);
