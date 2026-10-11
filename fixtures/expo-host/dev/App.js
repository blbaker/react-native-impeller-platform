// ci-expo-dev App: the Mac's probe App plus a render marker. The gate edits
// BG below while the app runs and expects Fast Refresh to repaint it.
import React from 'react';
import {Text, View} from 'react-native';
const BG = '#121213';
export default function App() {
  console.log('EXPO_DEV_RENDER ' + BG);
  return (
    <View style={{flex: 1, backgroundColor: BG, alignItems: 'center', justifyContent: 'center'}}>
      <Text style={{color: '#FFCB27', fontSize: 32}}>expo on impeller</Text>
    </View>
  );
}
