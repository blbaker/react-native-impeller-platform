/**
 * Native-driven Animated TRANSFORMS and the opacity pulse, one bundle, five
 * registered apps (pick one with --app-name).
 *
 * Asked by the macOS peer (internal request, HostApp ledger
 * DS-INPUT-SPIN): with useNativeDriver: true a rotating bar held a 100x20
 * bounding box on every frame while nativeanimated_ticks counted up. RN's
 * C++ TransformAnimatedNode sends `transform` as an operation list
 * ([{rotate: <radians>}]); the engine only accepted a flat 16-number matrix
 * and skipped it without a log line.
 *
 * Every subject is a white bar on black, centred in the surface, so a bright-
 * pixel bounding box and a centre-pixel luma are the whole measurement
 * (tools/ppm_bbox.py).
 *
 *   NativeRotateProbe     the peer's probe, same behaviour: rotate 0..360deg,
 *                         700 ms, Easing.linear, looped, useNativeDriver true
 *   NativeRotateIdle      the same tree with the loop NEVER started (negative
 *                         arm: the box must stay 100x20 on every frame)
 *   NativeOpacityPulse    skeleton-style pulse, opacity 1 -> 0.2 -> 1 over
 *                         1400 ms, one native timing looped (no JS per loop)
 *   NativeTranslateScale  translateX 0..70, translateY 0..40, scale 1..2,
 *                         700 ms linear, looped, native
 *   JsRotateProbe         NativeRotateProbe with useNativeDriver: false. The
 *                         cost arm's CONTROL: proves the per-frame JS-work
 *                         counters can see JS work when there is some.
 */
const React = require('react');
const { AppRegistry, View, Animated, Easing } = require('react-native');

const SCREEN = {
  flex: 1,
  alignItems: 'center',
  justifyContent: 'center',
  backgroundColor: '#000',
};
const BAR = { width: 100, height: 20, backgroundColor: '#fff' };

function useLoop(duration, useNativeDriver, start) {
  const v = React.useRef(new Animated.Value(0)).current;
  React.useEffect(() => {
    if (!start) return undefined;
    const loop = Animated.loop(
      Animated.timing(v, {
        toValue: 1,
        duration,
        easing: Easing.linear,
        useNativeDriver,
      }),
    );
    loop.start();
    return () => loop.stop();
  }, [v]);
  return v;
}

function rotateApp(useNativeDriver, start) {
  return function RotateProbe() {
    const v = useLoop(700, useNativeDriver, start);
    const rotate = v.interpolate({ inputRange: [0, 1], outputRange: ['0deg', '360deg'] });
    return React.createElement(
      View,
      { style: SCREEN },
      React.createElement(Animated.View, { style: [BAR, { transform: [{ rotate }] }] }),
    );
  };
}

function OpacityPulse() {
  const v = useLoop(1400, true, true);
  const opacity = v.interpolate({ inputRange: [0, 0.5, 1], outputRange: [1, 0.2, 1] });
  return React.createElement(
    View,
    { style: SCREEN },
    React.createElement(Animated.View, { style: [BAR, { opacity }] }),
  );
}

function TranslateScale() {
  const v = useLoop(700, true, true);
  const translateX = v.interpolate({ inputRange: [0, 1], outputRange: [0, 70] });
  const translateY = v.interpolate({ inputRange: [0, 1], outputRange: [0, 40] });
  const scale = v.interpolate({ inputRange: [0, 1], outputRange: [1, 2] });
  return React.createElement(
    View,
    { style: SCREEN },
    React.createElement(Animated.View, {
      style: [BAR, { transform: [{ translateX }, { translateY }, { scale }] }],
    }),
  );
}

AppRegistry.registerComponent('NativeRotateProbe', () => rotateApp(true, true));
AppRegistry.registerComponent('NativeRotateIdle', () => rotateApp(true, false));
AppRegistry.registerComponent('NativeOpacityPulse', () => OpacityPulse);
AppRegistry.registerComponent('NativeTranslateScale', () => TranslateScale);
AppRegistry.registerComponent('JsRotateProbe', () => rotateApp(false, true));
