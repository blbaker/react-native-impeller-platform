/**
 * FP-15 fixture for tools/ci-raster-thread.sh (windowed, 400x300 at --scale 1).
 * RasterTear: 12 boxes (60x60, 4 x 3 grid, centres at x = 50 + 90c, y = 50 + 90r) that
 *   ALWAYS share one colour per commit: commit n paints every box PALETTE[n % 7]. The
 *   next commit is scheduled from the effect of the previous one (setTimeout 0), so JS
 *   commits as fast as it can while the raster thread draws. A present whose samples
 *   mix two colours is a torn frame. Logs FP15_COMMITS n=<committed> every 250 commits.
 *   A native-driver rotation (bottom right, clear of the boxes) keeps NativeAnimated ticking.
 */
import React from 'react';
import {Animated, AppRegistry, Easing, View} from 'react-native';

const PALETTE = ['#ff0000', '#00ff00', '#0000ff', '#ffff00', '#ff00ff', '#00ffff', '#ffffff'];

function RasterTear() {
  const [n, setN] = React.useState(0);
  const spin = React.useRef(new Animated.Value(0)).current;
  React.useEffect(() => {
    Animated.loop(
      Animated.timing(spin, {toValue: 1, duration: 800, easing: Easing.linear, useNativeDriver: true}),
    ).start();
  }, [spin]);
  React.useEffect(() => {
    if (n > 0 && n % 250 === 0) console.log(`FP15_COMMITS n=${n}`);
    const id = setTimeout(() => setN((v) => v + 1), 0);
    return () => clearTimeout(id);
  }, [n]);
  const color = PALETTE[n % PALETTE.length];
  const boxes = [];
  for (let k = 0; k < 12; k++) {
    const c = k % 4;
    const r = Math.floor(k / 4);
    boxes.push(
      <View
        key={k}
        style={{position: 'absolute', left: 20 + c * 90, top: 20 + r * 90, width: 60, height: 60,
          backgroundColor: color}}
      />,
    );
  }
  const rotate = spin.interpolate({inputRange: [0, 1], outputRange: ['0deg', '360deg']});
  return (
    <View style={{flex: 1, backgroundColor: '#000000'}}>
      {boxes}
      <Animated.View
        style={{position: 'absolute', left: 360, top: 260, width: 30, height: 30,
          backgroundColor: '#808080', transform: [{rotate}]}}
      />
    </View>
  );
}

AppRegistry.registerComponent('RasterTear', () => RasterTear);
