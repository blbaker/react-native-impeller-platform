/**
 * ENG-17 fixture: Appearance.setColorScheme must re-render useColorScheme()
 * subscribers. Run with --color-scheme dark (the "system" scheme).
 *
 * Two apps in one bundle:
 *   Eng17ColorScheme  50 ms after mount: setColorScheme('light').
 *   Eng17Unspecified  50 ms: setColorScheme('light'); 150 ms:
 *                     setColorScheme('unspecified') -> back to the system's dark.
 * Logs:
 *   [js] ENG17 render scheme=<scheme>     every render of the subscriber
 *   [js] ENG17 set <s> get=<scheme>       getColorScheme() right after a set
 * The subscriber paints the surface #0a0a0a when dark, #ffffff when light.
 */
import React from 'react';
import {AppRegistry, Appearance, Text, View, useColorScheme} from 'react-native';

function Probe() {
  const scheme = useColorScheme();
  console.log(`ENG17 render scheme=${scheme}`);
  const dark = scheme === 'dark';
  return (
    <View style={{width: 200, height: 120, backgroundColor: dark ? '#0a0a0a' : '#ffffff'}}>
      <Text style={{color: dark ? '#ffffff' : '#000000', fontSize: 14, margin: 8}}>
        {`scheme=${scheme}`}
      </Text>
    </View>
  );
}

function set(s) {
  Appearance.setColorScheme(s);
  console.log(`ENG17 set ${s} get=${Appearance.getColorScheme()}`);
}

function Fixture() {
  React.useEffect(() => {
    const t = setTimeout(() => set('light'), 50);
    return () => clearTimeout(t);
  }, []);
  return <Probe />;
}

function Unspecified() {
  React.useEffect(() => {
    const t1 = setTimeout(() => set('light'), 50);
    const t2 = setTimeout(() => set('unspecified'), 150);
    return () => {
      clearTimeout(t1);
      clearTimeout(t2);
    };
  }, []);
  return <Probe />;
}

AppRegistry.registerComponent('Eng17ColorScheme', () => Fixture);
AppRegistry.registerComponent('Eng17Unspecified', () => Unspecified);
