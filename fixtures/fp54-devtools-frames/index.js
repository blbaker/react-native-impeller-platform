/**
 * FP-54 fixture: frames on demand for a DevTools trace.
 *
 * The app is idle (no presents under --idle-skip) until CDP evaluates
 * __fp54Animate(ms): a JS-driven Animated.timing moves a box for `ms`, so
 * every frame of the animation is a commit + present, and nothing presents
 * outside it. RN's own Fabric "layout" TimeStamps (track Renderer) mark the
 * animation's commits on RN's clock: the gate's independent anchor for our
 * frame timestamps. (JS console.timeStamp is the js-polyfills stub here.)
 */
import React from 'react';
import {Animated, AppRegistry, Easing, View} from 'react-native';

const x = new Animated.Value(0);
let runs = 0;
globalThis.__fp54Done = 0;

globalThis.__fp54Animate = ms => {
  runs += 1;
  const run = runs;
  Animated.timing(x, {
    toValue: run % 2 === 1 ? 300 : 0,
    duration: ms,
    easing: Easing.linear,
    useNativeDriver: false,
  }).start(() => {
    globalThis.__fp54Done = run;
  });
  return run;
};
console.log('FP54_BOOT');

function Fixture() {
  return (
    <View style={{flex: 1, backgroundColor: '#102030'}}>
      <Animated.View
        style={{
          position: 'absolute',
          top: 120,
          left: 20,
          width: 60,
          height: 60,
          backgroundColor: '#e08020',
          transform: [{translateX: x}],
        }}
      />
    </View>
  );
}

AppRegistry.registerComponent('Fp54DevtoolsFrames', () => Fixture);
