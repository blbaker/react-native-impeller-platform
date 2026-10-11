/**
 * SC-23 fixture: a useColorScheme() subscriber that never overrides the scheme.
 * Logs `SC23 render scheme=<s>` on every render; the box is #0a0a0a when dark,
 * #ffffff when light. Appearance.setColorScheme is called only by the
 * Sc23Override app, 300 ms after mount (to dark), to prove an app override beats the OS.
 */
import React from 'react';
import {AppRegistry, Appearance, Text, View, useColorScheme} from 'react-native';

function Probe() {
  const scheme = useColorScheme();
  console.log(`SC23 render scheme=${scheme}`);
  const dark = scheme === 'dark';
  return (
    <View style={{width: 200, height: 120, backgroundColor: dark ? '#0a0a0a' : '#ffffff'}}>
      <Text style={{color: dark ? '#ffffff' : '#000000', fontSize: 14, margin: 8}}>
        {`scheme=${scheme}`}
      </Text>
    </View>
  );
}

function Override() {
  React.useEffect(() => {
    const t = setTimeout(() => Appearance.setColorScheme('dark'), 300);
    return () => clearTimeout(t);
  }, []);
  return <Probe />;
}

AppRegistry.registerComponent('Sc23OsAppearance', () => Probe);
AppRegistry.registerComponent('Sc23Override', () => Override);
