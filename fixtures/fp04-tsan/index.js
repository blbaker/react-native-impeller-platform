/**
 * FP-04 fixture: cross-thread stress for tools/ci-tsan.sh (ThreadSanitizer build).
 * TsanTextChurn: 12 <Text> lines re-rendered every 4 ms (setInterval), so the JS
 *   thread measures paragraphs (ImpellerTextLayoutManager) while the main thread
 *   paints the previous commit's paragraphs with the same typography context.
 *   Line 0 carries a non-ASCII run so the font-fallback split runs on both threads.
 *   A native-driver Animated.loop rotation keeps NativeAnimated ticking alongside.
 *   An <Image> re-fetches a cache-busted URL every 8 ticks from tools/ci-tsan.sh's server on
 *   127.0.0.1:18932, so the fetch thread fires the scene damage wake while main paints.
 */
import React from 'react';
import {Animated, AppRegistry, Easing, Image, Text, View} from 'react-native';

function TsanTextChurn() {
  const [n, setN] = React.useState(0);
  const spin = React.useRef(new Animated.Value(0)).current;
  React.useEffect(() => {
    const id = setInterval(() => setN((v) => v + 1), 4);
    Animated.loop(
      Animated.timing(spin, {toValue: 1, duration: 1000, easing: Easing.linear, useNativeDriver: true}),
    ).start();
    return () => clearInterval(id);
  }, [spin]);
  const rotate = spin.interpolate({inputRange: [0, 1], outputRange: ['0deg', '360deg']});
  const lines = [];
  for (let k = 0; k < 12; k++) {
    lines.push(
      <Text key={k} style={{fontSize: 12 + (k % 4), fontWeight: k % 2 ? 'bold' : 'normal'}}>
        {k === 0 ? `tick ${n} éè ✓` : `line ${k} value ${(n * (k + 1)) % 9973}`}
      </Text>,
    );
  }
  return (
    <View style={{flex: 1, backgroundColor: '#ffffff', padding: 8}}>
      <Animated.View
        style={{position: 'absolute', right: 20, top: 20, width: 40, height: 40,
          backgroundColor: '#3060c0', transform: [{rotate}]}}
      />
      <Image
        style={{position: 'absolute', right: 20, top: 80, width: 16, height: 16}}
        source={{uri: `http://127.0.0.1:18932/churn.png?n=${Math.floor(n / 8)}`}}
      />
      {lines}
    </View>
  );
}

AppRegistry.registerComponent('TsanTextChurn', () => TsanTextChurn);
