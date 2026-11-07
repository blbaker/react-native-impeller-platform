// A consumer app's probe screen, verbatim
// except that the global.css import moved to entry.tsx so entry-nocss.tsx can
// reuse this file.
import { AppRegistry, Text, TextInput, View, type LayoutChangeEvent } from 'react-native';

const report = (name: string) => (e: LayoutChangeEvent) => console.log(`SPECIMEN ${JSON.stringify({ name, ...e.nativeEvent.layout })}`);
function Probe() {
  return (
    <View style={{ flex: 1, backgroundColor: '#121213' }}>
      <View onLayout={report('a')} style={{ position: 'absolute', left: 20, top: 20, width: 300, height: 40 }}>
        <TextInput placeholder="AAAA plain" style={{ width: 300, height: 40, fontSize: 18 }} />
      </View>
      <View onLayout={report('b')} style={{ position: 'absolute', left: 20, top: 80, width: 300, height: 40 }}>
        <TextInput placeholder="BBBB color" placeholderTextColor="#ff0000" style={{ width: 300, height: 40, fontSize: 18, color: '#ffffff' }} />
      </View>
      <View onLayout={report('d')} style={{ position: 'absolute', left: 20, top: 200, width: 300, height: 40 }}>
        <TextInput value="DDDD value" style={{ width: 300, height: 40, fontSize: 18, color: '#00ff00' }} />
      </View>
      <Text style={{ position: 'absolute', left: 20, top: 320, color: '#ffffff' }}>text ok</Text>
    </View>
  );
}
AppRegistry.registerComponent('Probe', () => Probe);
